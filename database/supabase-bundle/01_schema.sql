-- ============================================================================
-- Marketing Workflow Control Tower — full schema for Supabase
--
-- Paste into the Supabase SQL Editor and Run. Idempotent: safe to re-run.
-- Excludes the local auth shim; Supabase already provides auth.users/auth.uid().
-- Generated from app/supabase/migrations/ — edit there, not here.
-- ============================================================================


-- ####### 0001_core.sql #######

-- ============================================================================
-- 0001_core.sql — Users, roles, departments, approval authorities
-- ============================================================================
-- Nothing in this file names a real person, department or approver.
-- Those are all rows, inserted by seed/admin, never by DDL.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ----------------------------------------------------------------------------
-- users — a PERSON, who may or may not have a login
-- ----------------------------------------------------------------------------
-- There is deliberately NO foreign key to auth.users.
--
-- Most people named in the source job list will never sign in: they are who
-- work is attributed to, not accounts. Requiring an auth row for each of them
-- would mean fabricating login accounts, and auth.users is owned by Supabase's
-- auth service -- rows inserted into it by hand lack the columns GoTrue needs
-- and cannot authenticate.
--
-- For someone who DOES sign in, handle_new_auth_user() below creates their row
-- with id = auth.users.id, so `auth.uid() = users.id` still holds throughout
-- the row-level security policies. A person imported first and given a login
-- later is relinked by an admin; their placeholder email
-- (@placeholder.invalid) guarantees no collision in the meantime.
CREATE TABLE IF NOT EXISTS public.users (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email        TEXT NOT NULL UNIQUE,
  full_name    TEXT NOT NULL,
  avatar_url   TEXT,
  phone        TEXT,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login   TIMESTAMPTZ
);

-- ----------------------------------------------------------------------------
-- updated_at maintenance (shared by every table carrying the column)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_updated_at ON public.users;
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- Auto-create a profile row whenever Supabase Auth creates a user
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.users (id, email, full_name)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1))
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_on_auth_user_created ON auth.users;
CREATE TRIGGER trg_on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- ----------------------------------------------------------------------------
-- roles — capability sets. Permissions are data (JSONB), so a new permission
-- never requires a schema migration.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.roles (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL UNIQUE,
  description  TEXT,
  permissions  JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- A user may hold several roles (creator on one work type, approver on another)
CREATE TABLE IF NOT EXISTS public.user_roles (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role_id      UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  assigned_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  assigned_by  UUID REFERENCES public.users(id),
  UNIQUE (user_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_user_roles_user ON public.user_roles(user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role ON public.user_roles(role_id);

-- ----------------------------------------------------------------------------
-- departments — configuration, not an enum
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.departments (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  head_id     UUID REFERENCES public.users(id),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_departments_head ON public.departments(head_id);

-- ----------------------------------------------------------------------------
-- approval_authorities — THE configurable approval chain.
--
-- Instead of code saying "if branding then Parul approves", the engine asks:
--   "who approves work_category=X, at amount Y, at priority Z?"
-- and reads the answer out of this table. Changing an approver is an UPDATE,
-- not a deploy. The same table routes PO approvals (work_category='po'),
-- which is what keeps PO approvers out of the codebase.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.approval_authorities (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  approver_id     UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  work_category   TEXT NOT NULL,
  department_id   UUID REFERENCES public.departments(id),
  approval_level  INT NOT NULL DEFAULT 1,
  amount_min      NUMERIC(14,2) NOT NULL DEFAULT 0,
  amount_max      NUMERIC(14,2),          -- NULL = no upper bound
  applies_to_priority TEXT,               -- NULL = all priorities
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_amount_band CHECK (amount_max IS NULL OR amount_max >= amount_min)
);

CREATE INDEX IF NOT EXISTS idx_approval_auth_lookup
  ON public.approval_authorities(work_category, approval_level)
  WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_approval_auth_approver
  ON public.approval_authorities(approver_id);

-- ----------------------------------------------------------------------------
-- Baseline roles. These are capability names, not people — safe to ship as
-- DDL because they carry no organisational information.
-- ----------------------------------------------------------------------------
INSERT INTO public.roles (name, description, permissions) VALUES
  ('ADMIN',            'Full system administration',
   '["manage_users","manage_workflows","view_all","override_approvals","view_audit"]'),
  ('WORKFLOW_MANAGER', 'Oversees all work and reassignment',
   '["view_all","reassign_work","modify_deadlines","escalate","view_reports"]'),
  ('APPROVER',         'Approves work at approval stages',
   '["view_assigned","approve_work","request_changes","add_comments"]'),
  ('CREATOR',          'Produces the work',
   '["view_own","submit_work","upload_files","add_comments"]'),
  ('COORDINATOR',      'Creates and assigns work',
   '["create_work","view_all","assign_work","modify_deadlines","view_reports"]'),
  ('REQUESTOR',        'Raises requests',
   '["create_requests","view_own_requests"]'),
  ('VENDOR',           'External supplier',
   '["view_assigned","submit_deliverables"]')
ON CONFLICT (name) DO NOTHING;


-- ####### 0002_workflow.sql #######

-- ============================================================================
-- 0002_workflow.sql — Configurable workflow definition
-- ============================================================================
-- A workflow is a graph stored as rows:
--   workflow_templates  = the graph
--   workflow_stages     = the nodes
--   workflow_transitions= the edges, each labelled with what triggers it
--   stage_sla_config    = per-stage, per-priority deadline rules
--
-- The handoff engine never branches on a stage NAME. It looks up the edge
-- whose trigger_condition matches what just happened. That is what makes
-- "Approved goes forward, Changes Required goes back, PO required detours"
-- configuration rather than code.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.workflow_templates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  is_default  BOOLEAN NOT NULL DEFAULT FALSE,

  -- Resolves the "multiple people listed" ambiguity in the source data
  -- explicitly, per workflow, instead of the engine guessing per work item.
  multi_owner_behavior TEXT NOT NULL DEFAULT 'SINGLE',

  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_multi_owner CHECK (
    multi_owner_behavior IN ('SINGLE','PARALLEL','SEQUENTIAL','COLLABORATIVE')
  )
);

DROP TRIGGER IF EXISTS trg_workflow_templates_updated_at ON public.workflow_templates;
CREATE TRIGGER trg_workflow_templates_updated_at BEFORE UPDATE ON public.workflow_templates
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Only one template may be the default
CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_templates_one_default
  ON public.workflow_templates(is_default) WHERE is_default;

-- ----------------------------------------------------------------------------
-- workflow_stages — the nodes
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.workflow_stages (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id   UUID NOT NULL REFERENCES public.workflow_templates(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  stage_order   INT  NOT NULL,
  description   TEXT,

  -- Gate behaviour
  requires_approval   BOOLEAN NOT NULL DEFAULT FALSE,
  requires_attachment BOOLEAN NOT NULL DEFAULT FALSE,
  allowed_file_types  JSONB,
  required_fields     JSONB NOT NULL DEFAULT '[]'::jsonb,

  -- Who is expected to hold this stage. A ROLE, never a person.
  expected_role_id    UUID REFERENCES public.roles(id),

  -- Category used to look up approval_authorities when requires_approval.
  -- NULL means "use the job's category".
  approval_category   TEXT,

  -- Fallback SLA. stage_sla_config overrides per priority.
  -- NULL means "no SLA configured" -> the engine leaves the deadline NULL
  -- rather than inventing one.
  sla_days      INT,

  is_terminal   BOOLEAN NOT NULL DEFAULT FALSE,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (workflow_id, stage_order),
  UNIQUE (workflow_id, name)
);

CREATE INDEX IF NOT EXISTS idx_workflow_stages_workflow
  ON public.workflow_stages(workflow_id, stage_order);

-- ----------------------------------------------------------------------------
-- workflow_transitions — the edges
--
-- trigger_condition values are workflow vocabulary, not business rules:
--   SUBMISSION        - owner clicked Submit for Next Stage
--   APPROVED          - approver approved
--   CHANGES_REQUIRED  - approver sent it back
--   REJECTED          - approver killed it
--   PO_REQUIRED       - taken when work_items.po_required = true
--   NO_PO             - taken when work_items.po_required = false
--   PO_RELEASED       - procurement released the PO
--   VENDOR_COMPLETE   - external vendor delivered
--
-- to_stage_id NULL = workflow ends here.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.workflow_transitions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id       UUID NOT NULL REFERENCES public.workflow_templates(id) ON DELETE CASCADE,
  from_stage_id     UUID NOT NULL REFERENCES public.workflow_stages(id) ON DELETE CASCADE,
  to_stage_id       UUID REFERENCES public.workflow_stages(id) ON DELETE CASCADE,
  trigger_condition TEXT NOT NULL,
  description       TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (workflow_id, from_stage_id, trigger_condition),
  CONSTRAINT chk_trigger_condition CHECK (trigger_condition IN (
    'SUBMISSION','APPROVED','CHANGES_REQUIRED','REJECTED',
    'PO_REQUIRED','NO_PO','PO_RELEASED','VENDOR_COMPLETE'
  ))
);

CREATE INDEX IF NOT EXISTS idx_workflow_transitions_lookup
  ON public.workflow_transitions(from_stage_id, trigger_condition)
  WHERE is_active;

-- ----------------------------------------------------------------------------
-- stage_sla_config — deadlines as data, per stage and priority
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stage_sla_config (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stage_id   UUID NOT NULL REFERENCES public.workflow_stages(id) ON DELETE CASCADE,
  priority   TEXT NOT NULL,
  sla_days   INT  NOT NULL CHECK (sla_days >= 0),
  escalate_after_days INT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (stage_id, priority),
  CONSTRAINT chk_sla_priority CHECK (priority IN ('CRITICAL','HIGH','MEDIUM','LOW'))
);

CREATE INDEX IF NOT EXISTS idx_stage_sla_stage ON public.stage_sla_config(stage_id);


-- ####### 0003_work.sql #######

-- ============================================================================
-- 0003_work.sql — Campaigns, jobs, work items, owners, tasks
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.campaigns (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  description TEXT,
  starts_on   DATE,
  ends_on     DATE,
  created_by  UUID REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at  TIMESTAMPTZ
);

DROP TRIGGER IF EXISTS trg_campaigns_updated_at ON public.campaigns;
CREATE TRIGGER trg_campaigns_updated_at BEFORE UPDATE ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- jobs — the parent grouping ("Cardiac Campaign", "Sepsis Week")
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.jobs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL,
  description  TEXT,
  category     TEXT,
  -- Stable key for rows created by an import, e.g. 'joblist:8' = line 8 of the
  -- source document. Nullable (hand-created jobs have none) and UNIQUE, so an
  -- import can be re-run without duplicating what it already inserted.
  -- Postgres permits many NULLs in a UNIQUE column, so this constrains only
  -- imported rows.
  source_ref   TEXT UNIQUE,
  campaign_id  UUID REFERENCES public.campaigns(id) ON DELETE SET NULL,
  department_id UUID REFERENCES public.departments(id),
  requester_id UUID REFERENCES public.users(id),
  created_by   UUID REFERENCES public.users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at   TIMESTAMPTZ
);

DROP TRIGGER IF EXISTS trg_jobs_updated_at ON public.jobs;
CREATE TRIGGER trg_jobs_updated_at BEFORE UPDATE ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_jobs_category  ON public.jobs(category);
CREATE INDEX IF NOT EXISTS idx_jobs_campaign  ON public.jobs(campaign_id);
CREATE INDEX IF NOT EXISTS idx_jobs_requester ON public.jobs(requester_id);

-- ----------------------------------------------------------------------------
-- work_items — the deliverable that flows through the workflow
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.work_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id        UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,

  name          TEXT NOT NULL,
  description   TEXT,
  deliverable_type TEXT,

  -- Workflow position
  workflow_id       UUID NOT NULL REFERENCES public.workflow_templates(id),
  current_stage_id  UUID REFERENCES public.workflow_stages(id),
  previous_stage_id UUID REFERENCES public.workflow_stages(id),

  -- People. Four distinct questions, four columns.
  requester_id        UUID REFERENCES public.users(id),
  owner_id            UUID REFERENCES public.users(id),
  current_assignee_id UUID REFERENCES public.users(id),

  -- "Who is it pending with?" — the dashboard question that the assignee
  -- column cannot answer on its own. The assignee is accountable for the
  -- stage; pending_with is whose inbox the ball is actually in (often an
  -- approver or a vendor). The label column carries free text when the
  -- source data names no resolvable system user — e.g. the seed rule
  -- "approval pending -> pending_with = unknown".
  pending_with_id     UUID REFERENCES public.users(id),
  pending_with_label  TEXT,

  status     TEXT NOT NULL DEFAULT 'NOT_STARTED',
  substatus  TEXT,

  -- Deadlines are nullable on purpose: the source job list leaves several
  -- items undated and we must not invent one.
  deadline        DATE,
  stage_deadline  DATE,
  release_date    DATE,

  priority TEXT NOT NULL DEFAULT 'MEDIUM',

  -- Dependencies / blocking
  blocked_by_id   UUID REFERENCES public.work_items(id) ON DELETE SET NULL,
  blocker_type    TEXT,
  blocker_note    TEXT,

  -- Approval + PO flags (the routing values live in config tables)
  approval_required BOOLEAN NOT NULL DEFAULT FALSE,
  approval_status   TEXT NOT NULL DEFAULT 'NOT_REQUIRED',
  po_required       BOOLEAN NOT NULL DEFAULT FALSE,
  po_status         TEXT NOT NULL DEFAULT 'NOT_REQUIRED',
  estimated_amount  NUMERIC(14,2),

  -- Import provenance
  needs_review  BOOLEAN NOT NULL DEFAULT FALSE,
  review_notes  TEXT,
  source_text   TEXT,
  -- See jobs.source_ref. Makes the seed re-runnable and lets any row be traced
  -- back to the exact line of the source document it came from.
  source_ref    TEXT UNIQUE,

  submission_count INT NOT NULL DEFAULT 0,
  handoff_at    TIMESTAMPTZ,
  handoff_by    UUID REFERENCES public.users(id),

  created_by    UUID REFERENCES public.users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at  TIMESTAMPTZ,
  deleted_at    TIMESTAMPTZ,

  CONSTRAINT chk_work_status CHECK (status IN (
    'NOT_STARTED','IN_PROGRESS','SUBMITTED','PENDING','APPROVED',
    'CHANGES_REQUIRED','REJECTED','BLOCKED','ON_HOLD','COMPLETED','CANCELLED'
  )),
  CONSTRAINT chk_work_priority CHECK (priority IN ('CRITICAL','HIGH','MEDIUM','LOW')),
  CONSTRAINT chk_work_approval_status CHECK (approval_status IN (
    'NOT_REQUIRED','PENDING','APPROVED','CHANGES_REQUIRED','REJECTED'
  )),
  CONSTRAINT chk_work_po_status CHECK (po_status IN (
    'NOT_REQUIRED','NOT_STARTED','REQUESTED','IN_REVIEW','APPROVED','RELEASED','REJECTED'
  )),
  CONSTRAINT chk_blocker_type CHECK (blocker_type IS NULL OR blocker_type IN (
    'approval','vendor','budget','external','info_needed','dependency','other'
  ))
);

DROP TRIGGER IF EXISTS trg_work_items_updated_at ON public.work_items;
CREATE TRIGGER trg_work_items_updated_at BEFORE UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_work_items_job        ON public.work_items(job_id)              WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_owner      ON public.work_items(owner_id)            WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_assignee   ON public.work_items(current_assignee_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_pending    ON public.work_items(pending_with_id)     WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_stage      ON public.work_items(current_stage_id)    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_status     ON public.work_items(status)              WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_deadline   ON public.work_items(stage_deadline)      WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_priority   ON public.work_items(priority)            WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_work_items_review     ON public.work_items(needs_review)        WHERE needs_review;

-- ----------------------------------------------------------------------------
-- work_item_owners — collaborators
--
-- The source list frequently names several people ("Nirmal/Mudit/Shreyak").
-- They are all preserved here rather than one being picked arbitrarily.
-- How they are treated is decided by the workflow's multi_owner_behavior.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.work_item_owners (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  owner_role   TEXT NOT NULL DEFAULT 'COLLABORATOR',
  sequence_order INT,
  submission_status TEXT NOT NULL DEFAULT 'PENDING',
  submitted_at TIMESTAMPTZ,
  assigned_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  assigned_by  UUID REFERENCES public.users(id),

  UNIQUE (work_item_id, user_id),
  CONSTRAINT chk_owner_role CHECK (owner_role IN
    ('PRIMARY','COLLABORATOR','SUPPORT','REVIEWER')),
  CONSTRAINT chk_owner_submission_status CHECK (submission_status IN
    ('PENDING','SUBMITTED','APPROVED'))
);

CREATE INDEX IF NOT EXISTS idx_work_item_owners_user ON public.work_item_owners(user_id);

-- ----------------------------------------------------------------------------
-- tasks — a unit of work assigned to one person at one stage
--
-- Every handoff closes the outgoing task and opens a new one ("create next
-- task"). This table is the per-person queue that My Work reads, and it keeps
-- the history of who was asked to do what, at which stage, by when — which
-- work_items alone cannot express because it only holds current state.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tasks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id  UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  stage_id      UUID REFERENCES public.workflow_stages(id),

  assignee_id   UUID REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_by   UUID REFERENCES public.users(id),

  title         TEXT NOT NULL,
  instructions  TEXT,

  -- What this person must actually do, shown in My Work's "Pending Action"
  action_type   TEXT NOT NULL DEFAULT 'COMPLETE_STAGE',

  status        TEXT NOT NULL DEFAULT 'PENDING',
  priority      TEXT NOT NULL DEFAULT 'MEDIUM',
  due_date      DATE,

  opened_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at    TIMESTAMPTZ,
  closed_at     TIMESTAMPTZ,
  closed_reason TEXT,

  CONSTRAINT chk_task_status CHECK (status IN
    ('PENDING','IN_PROGRESS','SUBMITTED','COMPLETED','CANCELLED','ON_HOLD')),
  CONSTRAINT chk_task_priority CHECK (priority IN ('CRITICAL','HIGH','MEDIUM','LOW')),
  CONSTRAINT chk_task_action CHECK (action_type IN (
    'COMPLETE_STAGE','APPROVE','REVIEW','REVISE','RAISE_PO','APPROVE_PO',
    'RELEASE_PO','PRODUCE','PUBLISH','PROVIDE_INFO'
  ))
);

CREATE INDEX IF NOT EXISTS idx_tasks_assignee_open
  ON public.tasks(assignee_id, status) WHERE closed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_work_item ON public.tasks(work_item_id);
CREATE INDEX IF NOT EXISTS idx_tasks_due       ON public.tasks(due_date) WHERE closed_at IS NULL;

-- One open task per person per work item
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_one_open_per_assignee
  ON public.tasks(work_item_id, assignee_id) WHERE closed_at IS NULL;


-- ####### 0004_collab.sql #######

-- ============================================================================
-- 0004_collab.sql — Submissions, files, approvals, PO, comments, audit
-- ============================================================================

-- ----------------------------------------------------------------------------
-- submissions — append-only. Nothing is ever overwritten, which is what makes
-- the Return Rule's "preserve previous submission" hold.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.submissions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id      UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  task_id           UUID REFERENCES public.tasks(id) ON DELETE SET NULL,
  stage_id          UUID REFERENCES public.workflow_stages(id),
  submission_number INT  NOT NULL,
  submitted_by      UUID REFERENCES public.users(id),
  submitted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  notes             TEXT,
  snapshot          JSONB,
  UNIQUE (work_item_id, submission_number)
);

CREATE INDEX IF NOT EXISTS idx_submissions_work ON public.submissions(work_item_id, submitted_at DESC);

-- ----------------------------------------------------------------------------
-- files
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.files (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id  UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  submission_id UUID REFERENCES public.submissions(id) ON DELETE SET NULL,
  stage_id      UUID REFERENCES public.workflow_stages(id),

  file_name     TEXT NOT NULL,
  storage_path  TEXT NOT NULL,
  mime_type     TEXT,
  file_type     TEXT,
  size_bytes    BIGINT,

  uploaded_by   UUID REFERENCES public.users(id),
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_files_work ON public.files(work_item_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_files_submission ON public.files(submission_id);

-- ----------------------------------------------------------------------------
-- approvals — one row per decision taken (not per pending request; pending
-- state lives on work_items.approval_status)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.approvals (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id  UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  stage_id      UUID REFERENCES public.workflow_stages(id),
  submission_id UUID REFERENCES public.submissions(id) ON DELETE SET NULL,
  approver_id   UUID REFERENCES public.users(id),
  outcome       TEXT NOT NULL,
  reason        TEXT,
  decided_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_approval_outcome CHECK (outcome IN
    ('APPROVED','CHANGES_REQUIRED','REJECTED'))
);

CREATE INDEX IF NOT EXISTS idx_approvals_work     ON public.approvals(work_item_id, decided_at DESC);
CREATE INDEX IF NOT EXISTS idx_approvals_approver ON public.approvals(approver_id);

-- ----------------------------------------------------------------------------
-- po_requests — the PO approver is resolved from approval_authorities
-- (work_category = 'po'), never from a constant in code.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.po_requests (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id  UUID REFERENCES public.work_items(id) ON DELETE SET NULL,
  po_number     TEXT UNIQUE,

  vendor_name    TEXT,
  vendor_email   TEXT,
  vendor_user_id UUID REFERENCES public.users(id),

  amount    NUMERIC(14,2),
  currency  TEXT NOT NULL DEFAULT 'INR',
  description TEXT,

  status TEXT NOT NULL DEFAULT 'DRAFT',

  raised_by   UUID REFERENCES public.users(id),
  approved_by UUID REFERENCES public.users(id),

  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  submitted_at TIMESTAMPTZ,
  approved_at  TIMESTAMPTZ,
  released_at  TIMESTAMPTZ,

  CONSTRAINT chk_po_status CHECK (status IN
    ('DRAFT','SUBMITTED','IN_REVIEW','APPROVED','REJECTED','RELEASED','COMPLETED'))
);

DROP TRIGGER IF EXISTS trg_po_requests_updated_at ON public.po_requests;
CREATE TRIGGER trg_po_requests_updated_at BEFORE UPDATE ON public.po_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_po_requests_work   ON public.po_requests(work_item_id);
CREATE INDEX IF NOT EXISTS idx_po_requests_status ON public.po_requests(status);

-- work_items.po_id closes the loop now that po_requests exists
ALTER TABLE public.work_items
  ADD COLUMN IF NOT EXISTS po_request_id UUID REFERENCES public.po_requests(id) ON DELETE SET NULL;

-- ----------------------------------------------------------------------------
-- comments
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.comments (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  author_id    UUID REFERENCES public.users(id),
  parent_id    UUID REFERENCES public.comments(id) ON DELETE CASCADE,
  body         TEXT NOT NULL,
  comment_type TEXT NOT NULL DEFAULT 'COMMENT',
  is_resolved  BOOLEAN NOT NULL DEFAULT FALSE,
  resolved_by  UUID REFERENCES public.users(id),
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at   TIMESTAMPTZ,

  CONSTRAINT chk_comment_type CHECK (comment_type IN
    ('COMMENT','CHANGE_REQUEST','APPROVAL_NOTE','STATUS_UPDATE','HOLD_REASON'))
);

DROP TRIGGER IF EXISTS trg_comments_updated_at ON public.comments;
CREATE TRIGGER trg_comments_updated_at BEFORE UPDATE ON public.comments
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_comments_work ON public.comments(work_item_id, created_at DESC)
  WHERE deleted_at IS NULL;

-- ----------------------------------------------------------------------------
-- activity_log — append-only audit trail
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.activity_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  task_id      UUID REFERENCES public.tasks(id) ON DELETE SET NULL,
  actor_id     UUID REFERENCES public.users(id),
  action       TEXT NOT NULL,
  from_value   TEXT,
  to_value     TEXT,
  detail       JSONB,
  occurred_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_activity_work ON public.activity_log(work_item_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_actor ON public.activity_log(actor_id, occurred_at DESC);

-- ----------------------------------------------------------------------------
-- notifications
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notifications (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  work_item_id  UUID REFERENCES public.work_items(id) ON DELETE CASCADE,
  task_id       UUID REFERENCES public.tasks(id) ON DELETE CASCADE,
  type          TEXT NOT NULL,
  subject       TEXT,
  body          TEXT,
  action_url    TEXT,
  channel       TEXT NOT NULL DEFAULT 'IN_APP',
  sent_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  read_at       TIMESTAMPTZ,

  CONSTRAINT chk_notification_channel CHECK (channel IN ('IN_APP','EMAIL','SMS','SLACK'))
);

CREATE INDEX IF NOT EXISTS idx_notifications_unread
  ON public.notifications(recipient_id, sent_at DESC) WHERE read_at IS NULL;


-- ####### 0005_views.sql #######

-- ============================================================================
-- 0005_views.sql — Read models
-- ============================================================================
-- security_invoker = true is mandatory on every view here. Without it a view
-- executes with its OWNER's privileges and silently bypasses RLS on the
-- underlying tables, which would hand every user every row — the exact
-- opposite of "a user should see only tasks assigned to them".
-- ============================================================================

-- Dropped in reverse dependency order: v_my_tasks selects from v_work_items,
-- so dropping the base view first fails on any re-run. This file must stay
-- re-runnable — it is applied by pasting into the Supabase SQL Editor, which
-- people do repeatedly.
DROP VIEW IF EXISTS public.v_my_tasks;
DROP VIEW IF EXISTS public.v_work_items;

CREATE VIEW public.v_work_items WITH (security_invoker = true) AS
SELECT
  w.id,
  w.name,
  w.description,
  w.deliverable_type,

  w.job_id,
  j.name                AS job_name,
  j.category            AS job_category,
  j.campaign_id,
  c.name                AS campaign_name,

  w.workflow_id,
  wt.name               AS workflow_name,
  wt.multi_owner_behavior,
  w.current_stage_id,
  s.name                AS stage_name,
  s.stage_order,
  s.requires_approval   AS stage_requires_approval,
  s.is_terminal         AS stage_is_terminal,

  w.status,
  w.substatus,
  w.priority,

  w.owner_id,
  ow.full_name          AS owner_name,
  w.current_assignee_id,
  asg.full_name         AS assignee_name,

  w.pending_with_id,
  -- A single field the UI can render for "Pending With": the resolved user's
  -- name when we know them, else whatever the source told us (e.g. 'unknown').
  COALESCE(pw.full_name, w.pending_with_label) AS pending_with,

  w.deadline,
  w.stage_deadline,
  -- Days remaining counts against the stage deadline when one is set,
  -- otherwise the overall deadline. NULL when neither exists — an undated
  -- item shows "—", never a fabricated number.
  (COALESCE(w.stage_deadline, w.deadline) - CURRENT_DATE) AS days_remaining,
  (COALESCE(w.stage_deadline, w.deadline) IS NOT NULL
     AND COALESCE(w.stage_deadline, w.deadline) < CURRENT_DATE
     AND w.status NOT IN ('COMPLETED','CANCELLED','REJECTED'))     AS is_overdue,

  w.approval_required,
  w.approval_status,
  w.po_required,
  w.po_status,
  w.po_request_id,
  w.estimated_amount,

  w.blocked_by_id,
  w.blocker_type,
  w.blocker_note,

  w.needs_review,
  w.review_notes,
  w.source_text,

  w.submission_count,
  w.created_at,
  w.updated_at,
  w.completed_at
FROM public.work_items w
LEFT JOIN public.jobs               j   ON j.id  = w.job_id
LEFT JOIN public.campaigns          c   ON c.id  = j.campaign_id
LEFT JOIN public.workflow_templates wt  ON wt.id = w.workflow_id
LEFT JOIN public.workflow_stages    s   ON s.id  = w.current_stage_id
LEFT JOIN public.users              ow  ON ow.id = w.owner_id
LEFT JOIN public.users              asg ON asg.id= w.current_assignee_id
LEFT JOIN public.users              pw  ON pw.id = w.pending_with_id
WHERE w.deleted_at IS NULL;

-- ----------------------------------------------------------------------------
-- v_my_tasks — the My Work read model. One row per OPEN task assigned to the
-- caller.
--
-- The `assignee_id = auth.uid()` predicate below is REQUIRED and is not
-- redundant with RLS. The policy on `tasks` deliberately allows you to see
-- other people's tasks on work you are involved in — the Work Detail page
-- needs that to show who else is holding the item. So RLS alone answers
-- "tasks I may look at", which is a wider set than "tasks assigned to me".
-- Without this line an approver sees the designer's task in their own queue.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_my_tasks;
CREATE VIEW public.v_my_tasks WITH (security_invoker = true) AS
SELECT
  t.id                  AS task_id,
  t.work_item_id,
  t.assignee_id,
  t.title,
  t.instructions,
  t.action_type,
  t.status              AS task_status,
  t.priority            AS task_priority,
  t.due_date,
  t.opened_at,

  w.name                AS work_name,
  w.job_name,
  w.campaign_name,
  w.stage_name,
  w.stage_order,
  w.status              AS work_status,
  w.priority            AS work_priority,
  w.pending_with,
  w.owner_name,
  w.approval_status,
  w.po_status,

  COALESCE(t.due_date, w.stage_deadline, w.deadline)                    AS effective_due_date,
  (COALESCE(t.due_date, w.stage_deadline, w.deadline) - CURRENT_DATE)   AS days_remaining,
  (COALESCE(t.due_date, w.stage_deadline, w.deadline) IS NOT NULL
     AND COALESCE(t.due_date, w.stage_deadline, w.deadline) < CURRENT_DATE) AS is_overdue
FROM public.tasks t
JOIN public.v_work_items w ON w.id = t.work_item_id
WHERE t.closed_at IS NULL
  AND t.assignee_id = auth.uid();


-- ####### 0006_rls.sql #######

-- ============================================================================
-- 0006_rls.sql — Row Level Security
-- ============================================================================
-- Two rules drove this file:
--   1. Every table gets RLS ON *and* at least one policy. RLS enabled with no
--      policy denies everything to non-service-role callers — a silent lockout
--      that looks like an empty page rather than an error.
--   2. Config tables are readable by all authenticated users but writable only
--      by ADMIN. Left without RLS they would be world-writable through
--      PostgREST, letting any user rewrite the approval chain.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helper functions.
--
-- SECURITY DEFINER so a policy on table X can read user_roles without needing
-- a policy on user_roles that would recurse. STABLE so the planner evaluates
-- them once per statement instead of once per row — an inlined EXISTS(...)
-- subquery in every policy re-runs per row and gets slow fast.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_role(role_names TEXT[])
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r ON r.id = ur.role_id
    WHERE ur.user_id = auth.uid()
      AND r.is_active
      AND r.name = ANY(role_names)
  );
$$;

CREATE OR REPLACE FUNCTION public.has_permission(perm TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r ON r.id = ur.role_id
    WHERE ur.user_id = auth.uid()
      AND r.is_active
      AND r.permissions ? perm
  );
$$;

-- Can the current user see this work item at all?
CREATE OR REPLACE FUNCTION public.can_see_work_item(p_work_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR EXISTS (
      SELECT 1 FROM public.work_items w
      WHERE w.id = p_work_item_id
        AND (
          w.owner_id = auth.uid()
          OR w.current_assignee_id = auth.uid()
          OR w.pending_with_id = auth.uid()
          OR w.requester_id = auth.uid()
          OR w.created_by = auth.uid()
        )
    )
    OR EXISTS (
      SELECT 1 FROM public.work_item_owners o
      WHERE o.work_item_id = p_work_item_id AND o.user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM public.tasks t
      WHERE t.work_item_id = p_work_item_id AND t.assignee_id = auth.uid()
    );
$$;

-- Can the current user change it?
CREATE OR REPLACE FUNCTION public.can_edit_work_item(p_work_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER'])
    OR EXISTS (
      SELECT 1 FROM public.work_items w
      WHERE w.id = p_work_item_id
        AND (w.owner_id = auth.uid() OR w.current_assignee_id = auth.uid())
    )
    OR EXISTS (
      SELECT 1 FROM public.tasks t
      WHERE t.work_item_id = p_work_item_id
        AND t.assignee_id = auth.uid()
        AND t.closed_at IS NULL
    );
$$;

-- ============================================================================
-- Enable RLS everywhere
-- ============================================================================
ALTER TABLE public.users                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.departments          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approval_authorities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_templates   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_stages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_transitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stage_sla_config     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaigns            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_items           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_item_owners     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submissions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.files                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approvals            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.po_requests          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_log         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications        ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- users
-- ============================================================================
DROP POLICY IF EXISTS users_select ON public.users;
CREATE POLICY users_select ON public.users FOR SELECT TO authenticated
  USING (TRUE);   -- directory is visible: you must be able to see who work is pending with

DROP POLICY IF EXISTS users_update_self ON public.users;
CREATE POLICY users_update_self ON public.users FOR UPDATE TO authenticated
  USING (id = auth.uid() OR public.has_role(ARRAY['ADMIN']))
  WITH CHECK (id = auth.uid() OR public.has_role(ARRAY['ADMIN']));

DROP POLICY IF EXISTS users_admin_write ON public.users;
CREATE POLICY users_admin_write ON public.users FOR INSERT TO authenticated
  WITH CHECK (public.has_role(ARRAY['ADMIN']));

DROP POLICY IF EXISTS users_admin_delete ON public.users;
CREATE POLICY users_admin_delete ON public.users FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN']));

-- ============================================================================
-- Configuration tables: read for all authenticated, write for ADMIN only.
-- ============================================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'roles','user_roles','departments','approval_authorities',
    'workflow_templates','workflow_stages','workflow_transitions','stage_sla_config'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I_read ON public.%I', t, t);
    EXECUTE format(
      'CREATE POLICY %I_read ON public.%I FOR SELECT TO authenticated USING (TRUE)', t, t);

    EXECUTE format('DROP POLICY IF EXISTS %I_admin_write ON public.%I', t, t);
    EXECUTE format(
      'CREATE POLICY %I_admin_write ON public.%I FOR ALL TO authenticated
         USING (public.has_role(ARRAY[''ADMIN'']))
         WITH CHECK (public.has_role(ARRAY[''ADMIN'']))', t, t);
  END LOOP;
END $$;

-- ============================================================================
-- campaigns / jobs — visible to all authenticated; writable by coordinators
-- ============================================================================
DROP POLICY IF EXISTS campaigns_read ON public.campaigns;
CREATE POLICY campaigns_read ON public.campaigns FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS campaigns_write ON public.campaigns;
CREATE POLICY campaigns_write ON public.campaigns FOR ALL TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR']))
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR']));

DROP POLICY IF EXISTS jobs_read ON public.jobs;
CREATE POLICY jobs_read ON public.jobs FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS jobs_write ON public.jobs;
CREATE POLICY jobs_write ON public.jobs FOR ALL TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid())
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid());

-- ============================================================================
-- work_items
-- ============================================================================
DROP POLICY IF EXISTS work_items_select ON public.work_items;
CREATE POLICY work_items_select ON public.work_items FOR SELECT TO authenticated
  USING (public.can_see_work_item(id));

DROP POLICY IF EXISTS work_items_insert ON public.work_items;
CREATE POLICY work_items_insert ON public.work_items FOR INSERT TO authenticated
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR']));

DROP POLICY IF EXISTS work_items_update ON public.work_items;
CREATE POLICY work_items_update ON public.work_items FOR UPDATE TO authenticated
  USING (public.can_edit_work_item(id))
  WITH CHECK (public.can_edit_work_item(id));

DROP POLICY IF EXISTS work_items_delete ON public.work_items;
CREATE POLICY work_items_delete ON public.work_items FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN']));

-- ============================================================================
-- work_item_owners
-- ============================================================================
DROP POLICY IF EXISTS work_item_owners_select ON public.work_item_owners;
CREATE POLICY work_item_owners_select ON public.work_item_owners FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS work_item_owners_write ON public.work_item_owners;
CREATE POLICY work_item_owners_write ON public.work_item_owners FOR ALL TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR public.can_edit_work_item(work_item_id))
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR public.can_edit_work_item(work_item_id));

-- ============================================================================
-- tasks — the My Work guarantee
-- ============================================================================
DROP POLICY IF EXISTS tasks_select ON public.tasks;
CREATE POLICY tasks_select ON public.tasks FOR SELECT TO authenticated
  USING (
    assignee_id = auth.uid()
    OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR public.can_see_work_item(work_item_id)
  );

DROP POLICY IF EXISTS tasks_update ON public.tasks;
CREATE POLICY tasks_update ON public.tasks FOR UPDATE TO authenticated
  USING (assignee_id = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR']))
  WITH CHECK (assignee_id = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR']));

DROP POLICY IF EXISTS tasks_insert ON public.tasks;
CREATE POLICY tasks_insert ON public.tasks FOR INSERT TO authenticated
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
              OR public.can_edit_work_item(work_item_id));

DROP POLICY IF EXISTS tasks_delete ON public.tasks;
CREATE POLICY tasks_delete ON public.tasks FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN']));

-- ============================================================================
-- submissions / files / approvals / comments / activity_log — scoped to the
-- work item's visibility
-- ============================================================================
DROP POLICY IF EXISTS submissions_select ON public.submissions;
CREATE POLICY submissions_select ON public.submissions FOR SELECT TO authenticated
  USING (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS submissions_insert ON public.submissions;
CREATE POLICY submissions_insert ON public.submissions FOR INSERT TO authenticated
  WITH CHECK (public.can_edit_work_item(work_item_id));

DROP POLICY IF EXISTS files_select ON public.files;
CREATE POLICY files_select ON public.files FOR SELECT TO authenticated
  USING (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS files_insert ON public.files;
CREATE POLICY files_insert ON public.files FOR INSERT TO authenticated
  WITH CHECK (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS files_update ON public.files;
CREATE POLICY files_update ON public.files FOR UPDATE TO authenticated
  USING (uploaded_by = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']))
  WITH CHECK (uploaded_by = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']));

DROP POLICY IF EXISTS approvals_select ON public.approvals;
CREATE POLICY approvals_select ON public.approvals FOR SELECT TO authenticated
  USING (approver_id = auth.uid() OR public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS approvals_insert ON public.approvals;
CREATE POLICY approvals_insert ON public.approvals FOR INSERT TO authenticated
  WITH CHECK (approver_id = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']));

DROP POLICY IF EXISTS po_requests_select ON public.po_requests;
CREATE POLICY po_requests_select ON public.po_requests FOR SELECT TO authenticated
  USING (
    raised_by = auth.uid() OR approved_by = auth.uid() OR vendor_user_id = auth.uid()
    OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR (work_item_id IS NOT NULL AND public.can_see_work_item(work_item_id))
  );

DROP POLICY IF EXISTS po_requests_write ON public.po_requests;
CREATE POLICY po_requests_write ON public.po_requests FOR ALL TO authenticated
  USING (raised_by = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR']))
  WITH CHECK (raised_by = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR']));

DROP POLICY IF EXISTS comments_select ON public.comments;
CREATE POLICY comments_select ON public.comments FOR SELECT TO authenticated
  USING (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS comments_insert ON public.comments;
CREATE POLICY comments_insert ON public.comments FOR INSERT TO authenticated
  WITH CHECK (author_id = auth.uid() AND public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS comments_update ON public.comments;
CREATE POLICY comments_update ON public.comments FOR UPDATE TO authenticated
  USING (author_id = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']))
  WITH CHECK (author_id = auth.uid() OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']));

DROP POLICY IF EXISTS activity_log_select ON public.activity_log;
CREATE POLICY activity_log_select ON public.activity_log FOR SELECT TO authenticated
  USING (public.can_see_work_item(work_item_id));

-- Audit rows are written by the handoff functions, never edited or removed.
DROP POLICY IF EXISTS activity_log_insert ON public.activity_log;
CREATE POLICY activity_log_insert ON public.activity_log FOR INSERT TO authenticated
  WITH CHECK (public.can_see_work_item(work_item_id));

-- ============================================================================
-- notifications — strictly your own
-- ============================================================================
DROP POLICY IF EXISTS notifications_select ON public.notifications;
CREATE POLICY notifications_select ON public.notifications FOR SELECT TO authenticated
  USING (recipient_id = auth.uid());

DROP POLICY IF EXISTS notifications_update ON public.notifications;
CREATE POLICY notifications_update ON public.notifications FOR UPDATE TO authenticated
  USING (recipient_id = auth.uid())
  WITH CHECK (recipient_id = auth.uid());

-- Handoffs create notifications for the NEXT user, so insert cannot be
-- restricted to recipient_id = auth.uid().
DROP POLICY IF EXISTS notifications_insert ON public.notifications;
CREATE POLICY notifications_insert ON public.notifications FOR INSERT TO authenticated
  WITH CHECK (
    work_item_id IS NULL OR public.can_see_work_item(work_item_id)
  );

-- ============================================================================
-- Table-level privileges
--
-- RLS filters ROWS; GRANT controls whether the role may touch the table at
-- all. Supabase grants these to `authenticated` by default, but relying on
-- that makes the migration non-portable and hides the intent — so they are
-- declared here. With RLS enabled above, a broad GRANT is still safe: every
-- statement is filtered by the policies.
-- ============================================================================
GRANT USAGE ON SCHEMA public TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO authenticated;

-- The audit trail is append-only for everybody: no UPDATE, no DELETE.
REVOKE UPDATE, DELETE ON public.activity_log FROM authenticated;
-- Submissions are immutable once written (the Return Rule depends on it).
REVOKE UPDATE, DELETE ON public.submissions  FROM authenticated;
-- Approval decisions are a record of what was decided, not a mutable field.
REVOKE UPDATE, DELETE ON public.approvals    FROM authenticated;


-- ####### 0007_handoff.sql #######

-- ============================================================================
-- 0007_handoff.sql — Automatic handoff engine
-- ============================================================================
-- Why this lives in plpgsql and not in TypeScript:
--
-- One handoff writes to submissions, tasks (close + open), work_items,
-- work_item_owners, activity_log and notifications. If it half-applies, the
-- work item disappears from BOTH people's queues — the submitter has closed
-- their task and the next person never got one. The Supabase JS client cannot
-- open a transaction across statements, so the whole mutation is one function
-- and therefore one transaction: it either all lands or none of it does.
--
-- SECURITY INVOKER (the default) is deliberate: the function runs as the
-- caller, so RLS still applies and nobody can hand off work they cannot see.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Deadline for a stage, as configuration.
-- Returns NULL when no SLA is configured — the caller then leaves the deadline
-- empty rather than inventing one.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_stage_deadline(
  p_stage_id UUID,
  p_priority TEXT
) RETURNS DATE LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_days INT;
BEGIN
  SELECT sla_days INTO v_days
  FROM public.stage_sla_config
  WHERE stage_id = p_stage_id AND priority = p_priority;

  IF v_days IS NULL THEN
    SELECT sla_days INTO v_days
    FROM public.workflow_stages
    WHERE id = p_stage_id;
  END IF;

  IF v_days IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN CURRENT_DATE + v_days;
END;
$$;

-- ----------------------------------------------------------------------------
-- Who should hold a stage next?
--
-- Approval stages resolve through approval_authorities (category + amount band
-- + priority). Everything else resolves to a collaborator holding the stage's
-- expected role, falling back to the work item's owner.
--
-- Returns NULL when nothing matches. That is a real answer, not a failure:
-- the caller parks the item as unassigned so it surfaces on the Control Tower
-- instead of being silently handed to an arbitrary person.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_next_assignee(
  p_work_item_id UUID,
  p_stage_id     UUID
) RETURNS UUID LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_requires_approval BOOLEAN;
  v_expected_role_id  UUID;
  v_approval_category TEXT;
  v_job_category      TEXT;
  v_priority          TEXT;
  v_amount            NUMERIC;
  v_owner_id          UUID;
  v_assignee          UUID;
BEGIN
  SELECT s.requires_approval, s.expected_role_id, s.approval_category
    INTO v_requires_approval, v_expected_role_id, v_approval_category
  FROM public.workflow_stages s WHERE s.id = p_stage_id;

  SELECT j.category, w.priority, w.estimated_amount, w.owner_id
    INTO v_job_category, v_priority, v_amount, v_owner_id
  FROM public.work_items w
  JOIN public.jobs j ON j.id = w.job_id
  WHERE w.id = p_work_item_id;

  IF v_requires_approval THEN
    SELECT aa.approver_id INTO v_assignee
    FROM public.approval_authorities aa
    WHERE aa.is_active
      AND aa.work_category = COALESCE(v_approval_category, v_job_category)
      AND COALESCE(v_amount, 0) >= aa.amount_min
      AND (aa.amount_max IS NULL OR COALESCE(v_amount, 0) <= aa.amount_max)
      AND (aa.applies_to_priority IS NULL OR aa.applies_to_priority = v_priority)
    ORDER BY aa.approval_level, aa.created_at
    LIMIT 1;

    RETURN v_assignee;  -- may be NULL: no authority configured for this category
  END IF;

  IF v_expected_role_id IS NOT NULL THEN
    SELECT o.user_id INTO v_assignee
    FROM public.work_item_owners o
    JOIN public.user_roles ur ON ur.user_id = o.user_id
    WHERE o.work_item_id = p_work_item_id
      AND ur.role_id = v_expected_role_id
    ORDER BY CASE o.owner_role WHEN 'PRIMARY' THEN 0 ELSE 1 END, o.assigned_at
    LIMIT 1;

    IF v_assignee IS NOT NULL THEN
      RETURN v_assignee;
    END IF;
  END IF;

  RETURN v_owner_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Which edge do we take out of this stage on a submit?
--
-- If the stage defines PO branching edges, the po_required flag picks between
-- them. Otherwise the plain SUBMISSION edge is taken. No stage NAME is ever
-- tested, so renaming or reordering stages cannot break routing.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_submit_trigger(
  p_stage_id    UUID,
  p_po_required BOOLEAN
) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_has_po_edges BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.workflow_transitions
    WHERE from_stage_id = p_stage_id
      AND is_active
      AND trigger_condition IN ('PO_REQUIRED','NO_PO')
  ) INTO v_has_po_edges;

  IF v_has_po_edges THEN
    RETURN CASE WHEN p_po_required THEN 'PO_REQUIRED' ELSE 'NO_PO' END;
  END IF;

  RETURN 'SUBMISSION';
END;
$$;

-- ============================================================================
-- submit_for_next_stage
-- ============================================================================
CREATE OR REPLACE FUNCTION public.submit_for_next_stage(
  p_work_item_id UUID,
  p_notes        TEXT DEFAULT NULL,
  p_file_ids     UUID[] DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor          UUID := auth.uid();
  v_work           public.work_items%ROWTYPE;
  v_stage          public.workflow_stages%ROWTYPE;
  v_multi_mode     TEXT;
  v_task           public.tasks%ROWTYPE;
  v_trigger        TEXT;
  v_next_stage_id  UUID;
  v_next_stage     public.workflow_stages%ROWTYPE;
  v_transition_found BOOLEAN;
  v_next_assignee  UUID;
  v_next_deadline  DATE;
  v_submission_id  UUID;
  v_submission_no  INT;
  v_new_task_id    UUID;
  v_pending_total  INT;
  v_missing_files  INT;
  v_next_status    TEXT;
  v_action_type    TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  -- Lock the row for the duration of the transaction so two people clicking
  -- Submit at the same moment cannot both advance the stage.
  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot be submitted', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before submitting.'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  SELECT multi_owner_behavior INTO v_multi_mode
  FROM public.workflow_templates WHERE id = v_work.workflow_id;

  -- ---- 1. VALIDATE -------------------------------------------------------
  -- The caller must actually hold this work: an open task, or be the
  -- assignee/owner. Anything else is rejected even if RLS let them read it.
  SELECT * INTO v_task FROM public.tasks
  WHERE work_item_id = p_work_item_id
    AND assignee_id = v_actor
    AND closed_at IS NULL
  LIMIT 1;

  IF NOT FOUND
     AND v_work.current_assignee_id IS DISTINCT FROM v_actor
     AND v_work.owner_id IS DISTINCT FROM v_actor
     AND NOT EXISTS (
       SELECT 1 FROM public.work_item_owners
       WHERE work_item_id = p_work_item_id AND user_id = v_actor
     )
  THEN
    RAISE EXCEPTION 'You do not hold this work item' USING ERRCODE = '42501';
  END IF;

  IF v_stage.requires_attachment THEN
    SELECT COUNT(*) INTO v_missing_files
    FROM public.files
    WHERE work_item_id = p_work_item_id
      AND deleted_at IS NULL
      AND (stage_id = v_stage.id OR stage_id IS NULL);

    IF v_missing_files = 0 THEN
      RAISE EXCEPTION 'Stage "%" requires at least one attachment', v_stage.name
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- ---- 2. RECORD THE SUBMISSION (append-only) ----------------------------
  v_submission_no := COALESCE(v_work.submission_count, 0) + 1;

  INSERT INTO public.submissions (
    work_item_id, task_id, stage_id, submission_number, submitted_by, notes, snapshot
  ) VALUES (
    p_work_item_id, v_task.id, v_stage.id, v_submission_no, v_actor, p_notes,
    jsonb_build_object(
      'status', v_work.status,
      'stage_id', v_work.current_stage_id,
      'stage_name', v_stage.name,
      'assignee_id', v_work.current_assignee_id,
      'priority', v_work.priority,
      'stage_deadline', v_work.stage_deadline
    )
  ) RETURNING id INTO v_submission_id;

  IF p_file_ids IS NOT NULL THEN
    UPDATE public.files
    SET submission_id = v_submission_id
    WHERE id = ANY(p_file_ids) AND work_item_id = p_work_item_id;
  END IF;

  -- Close this person's task
  IF v_task.id IS NOT NULL THEN
    UPDATE public.tasks
    SET status = 'SUBMITTED', closed_at = NOW(), closed_reason = 'Submitted for next stage'
    WHERE id = v_task.id;
  END IF;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, detail)
  VALUES (p_work_item_id, v_task.id, v_actor, 'SUBMITTED',
          jsonb_build_object('stage', v_stage.name, 'submission_number', v_submission_no,
                             'notes', p_notes));

  -- ---- 3. MULTI-OWNER GATE ----------------------------------------------
  -- PARALLEL work only advances once every collaborator has submitted.
  IF v_multi_mode = 'PARALLEL' THEN
    UPDATE public.work_item_owners
    SET submission_status = 'SUBMITTED', submitted_at = NOW()
    WHERE work_item_id = p_work_item_id AND user_id = v_actor;

    SELECT COUNT(*) INTO v_pending_total
    FROM public.work_item_owners
    WHERE work_item_id = p_work_item_id AND submission_status = 'PENDING';

    IF v_pending_total > 0 THEN
      UPDATE public.work_items
      SET status = 'SUBMITTED',
          substatus = format('Waiting on %s more collaborator(s)', v_pending_total),
          submission_count = v_submission_no
      WHERE id = p_work_item_id;

      -- Nudge whoever is still holding it
      INSERT INTO public.notifications (recipient_id, work_item_id, type, subject, body, action_url)
      SELECT o.user_id, p_work_item_id, 'ASSIGNMENT',
             format('Still awaiting your submission: %s', v_work.name),
             format('%s has submitted. This work advances once all collaborators submit.',
                    (SELECT full_name FROM public.users WHERE id = v_actor)),
             '/work/' || p_work_item_id
      FROM public.work_item_owners o
      WHERE o.work_item_id = p_work_item_id AND o.submission_status = 'PENDING';

      RETURN jsonb_build_object(
        'advanced', FALSE,
        'reason', 'awaiting_collaborators',
        'pending_collaborators', v_pending_total,
        'submission_id', v_submission_id
      );
    END IF;
  END IF;

  -- SEQUENTIAL hands to the next collaborator in order before leaving the stage.
  IF v_multi_mode = 'SEQUENTIAL' THEN
    UPDATE public.work_item_owners
    SET submission_status = 'SUBMITTED', submitted_at = NOW()
    WHERE work_item_id = p_work_item_id AND user_id = v_actor;

    SELECT o.user_id INTO v_next_assignee
    FROM public.work_item_owners o
    WHERE o.work_item_id = p_work_item_id
      AND o.submission_status = 'PENDING'
    ORDER BY o.sequence_order NULLS LAST, o.assigned_at
    LIMIT 1;

    IF v_next_assignee IS NOT NULL THEN
      v_next_deadline := public.compute_stage_deadline(v_stage.id, v_work.priority);

      INSERT INTO public.tasks (
        work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
        action_type, priority, due_date
      ) VALUES (
        p_work_item_id, v_stage.id, v_next_assignee, v_actor,
        format('%s — %s', v_work.name, v_stage.name),
        p_notes, 'COMPLETE_STAGE', v_work.priority, v_next_deadline
      ) RETURNING id INTO v_new_task_id;

      UPDATE public.work_items
      SET current_assignee_id = v_next_assignee,
          pending_with_id     = v_next_assignee,
          pending_with_label  = NULL,
          status              = 'IN_PROGRESS',
          stage_deadline      = v_next_deadline,
          submission_count    = v_submission_no,
          handoff_at          = NOW(),
          handoff_by          = v_actor
      WHERE id = p_work_item_id;

      INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value)
      VALUES (p_work_item_id, v_new_task_id, v_actor, 'ASSIGNED',
              (SELECT full_name FROM public.users WHERE id = v_actor),
              (SELECT full_name FROM public.users WHERE id = v_next_assignee));

      INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
      VALUES (v_next_assignee, p_work_item_id, v_new_task_id, 'ASSIGNMENT',
              format('Your turn: %s', v_work.name),
              format('Handed to you at stage %s.', v_stage.name),
              '/work/' || p_work_item_id);

      RETURN jsonb_build_object(
        'advanced', FALSE,
        'reason', 'sequential_handoff',
        'next_assignee_id', v_next_assignee,
        'task_id', v_new_task_id
      );
    END IF;
  END IF;

  -- ---- 4. MOVE STAGE -----------------------------------------------------
  v_trigger := public.resolve_submit_trigger(v_stage.id, v_work.po_required);

  SELECT t.to_stage_id, TRUE INTO v_next_stage_id, v_transition_found
  FROM public.workflow_transitions t
  WHERE t.from_stage_id = v_stage.id
    AND t.trigger_condition = v_trigger
    AND t.is_active
  LIMIT 1;

  IF NOT COALESCE(v_transition_found, FALSE) THEN
    RAISE EXCEPTION 'No % transition configured out of stage "%"', v_trigger, v_stage.name
      USING ERRCODE = '22023',
            HINT = 'Add a workflow_transitions row for this stage.';
  END IF;

  -- End of workflow
  IF v_next_stage_id IS NULL THEN
    UPDATE public.work_items
    SET status = 'COMPLETED',
        previous_stage_id = v_stage.id,
        current_stage_id  = NULL,
        current_assignee_id = NULL,
        pending_with_id   = NULL,
        pending_with_label= NULL,
        stage_deadline    = NULL,
        submission_count  = v_submission_no,
        completed_at      = NOW(),
        handoff_at        = NOW(),
        handoff_by        = v_actor
    WHERE id = p_work_item_id;

    INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value)
    VALUES (p_work_item_id, v_actor, 'COMPLETED', v_stage.name, NULL);

    RETURN jsonb_build_object('advanced', TRUE, 'completed', TRUE,
                              'submission_id', v_submission_id);
  END IF;

  SELECT * INTO v_next_stage FROM public.workflow_stages WHERE id = v_next_stage_id;

  -- ---- 5. IDENTIFY NEXT ASSIGNEE ----------------------------------------
  v_next_assignee := public.resolve_next_assignee(p_work_item_id, v_next_stage_id);
  v_next_deadline := public.compute_stage_deadline(v_next_stage_id, v_work.priority);

  v_action_type := CASE
    WHEN v_next_stage.requires_approval THEN 'APPROVE'
    ELSE 'COMPLETE_STAGE'
  END;

  -- A workflow can end two ways: a transition pointing at nothing (handled
  -- above), or landing on a stage flagged is_terminal. The 11-stage flow uses
  -- the second form because "Completed" is a real stage users need to see in
  -- the progress tracker -- without this it would sit there as IN_PROGRESS.
  v_next_status := CASE
    WHEN v_next_stage.is_terminal       THEN 'COMPLETED'
    WHEN v_next_stage.requires_approval THEN 'PENDING'
    WHEN v_next_assignee IS NULL        THEN 'PENDING'
    ELSE 'IN_PROGRESS'
  END;

  -- ---- 6. CREATE NEXT TASK ----------------------------------------------
  -- No task on a terminal stage: there is nothing left for anyone to do.
  IF v_next_assignee IS NOT NULL AND NOT v_next_stage.is_terminal THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id, v_next_stage_id, v_next_assignee, v_actor,
      format('%s — %s', v_work.name, v_next_stage.name),
      p_notes, v_action_type, v_work.priority, v_next_deadline
    ) RETURNING id INTO v_new_task_id;
  END IF;

  -- Reset collaborator submission flags for the new stage
  UPDATE public.work_item_owners
  SET submission_status = 'PENDING', submitted_at = NULL
  WHERE work_item_id = p_work_item_id;

  UPDATE public.work_items
  SET previous_stage_id  = v_stage.id,
      current_stage_id   = v_next_stage_id,
      -- Finished work is pending with nobody. Leaving an assignee on a
      -- terminal stage would keep it sitting in that person's My Work queue
      -- forever.
      current_assignee_id= CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_assignee END,
      pending_with_id    = CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_assignee END,
      pending_with_label = CASE
                             WHEN v_next_stage.is_terminal THEN NULL
                             WHEN v_next_assignee IS NULL   THEN 'unassigned'
                             ELSE NULL END,
      status             = v_next_status,
      substatus          = NULL,
      approval_required  = v_next_stage.requires_approval,
      approval_status    = CASE WHEN v_next_stage.requires_approval
                                THEN 'PENDING' ELSE approval_status END,
      stage_deadline     = CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_deadline END,
      submission_count   = v_submission_no,
      completed_at       = CASE WHEN v_next_stage.is_terminal THEN NOW() ELSE completed_at END,
      handoff_at         = NOW(),
      handoff_by         = v_actor
  WHERE id = p_work_item_id;

  -- ---- 7. ACTIVITY LOG ---------------------------------------------------
  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_new_task_id, v_actor, 'STAGE_CHANGED',
          v_stage.name, v_next_stage.name,
          jsonb_build_object('trigger', v_trigger, 'submission_id', v_submission_id));

  IF v_next_assignee IS NOT NULL THEN
    INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, to_value)
    VALUES (p_work_item_id, v_new_task_id, v_actor, 'ASSIGNED',
            (SELECT full_name FROM public.users WHERE id = v_next_assignee));
  ELSE
    INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
    VALUES (p_work_item_id, v_actor, 'UNASSIGNED',
            jsonb_build_object('reason', 'no approval authority or owner configured',
                               'stage', v_next_stage.name));
  END IF;

  -- ---- 8. NOTIFY ---------------------------------------------------------
  IF v_next_assignee IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
    VALUES (
      v_next_assignee, p_work_item_id, v_new_task_id,
      CASE WHEN v_next_stage.requires_approval THEN 'APPROVAL_REQUIRED' ELSE 'ASSIGNMENT' END,
      format('%s: %s', CASE WHEN v_next_stage.requires_approval
                            THEN 'Approval needed' ELSE 'New work assigned' END, v_work.name),
      format('Stage: %s. %s',
             v_next_stage.name,
             COALESCE('Due ' || v_next_deadline::TEXT, 'No due date set')),
      '/work/' || p_work_item_id
    );
  END IF;

  RETURN jsonb_build_object(
    'advanced', TRUE,
    'completed', FALSE,
    'from_stage', v_stage.name,
    'to_stage', v_next_stage.name,
    'trigger', v_trigger,
    'next_assignee_id', v_next_assignee,
    'task_id', v_new_task_id,
    'stage_deadline', v_next_deadline,
    'submission_id', v_submission_id
  );
END;
$$;

-- ============================================================================
-- request_changes — the Return Rule
-- ============================================================================
CREATE OR REPLACE FUNCTION public.request_changes(
  p_work_item_id UUID,
  p_reason       TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor         UUID := auth.uid();
  v_work          public.work_items%ROWTYPE;
  v_stage         public.workflow_stages%ROWTYPE;
  v_target_id     UUID;
  v_target        public.workflow_stages%ROWTYPE;
  v_found         BOOLEAN;
  v_prev_owner    UUID;
  v_deadline      DATE;
  v_task_id       UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required when requesting changes'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;

  SELECT t.to_stage_id, TRUE INTO v_target_id, v_found
  FROM public.workflow_transitions t
  WHERE t.from_stage_id = v_work.current_stage_id
    AND t.trigger_condition = 'CHANGES_REQUIRED'
    AND t.is_active
  LIMIT 1;

  -- Fall back to the stage the item actually came from when the workflow
  -- doesn't define an explicit rollback edge.
  IF NOT COALESCE(v_found, FALSE) THEN
    v_target_id := v_work.previous_stage_id;
  END IF;

  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'Nowhere to send this back to' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_target FROM public.workflow_stages WHERE id = v_target_id;

  -- Send it back to whoever submitted it last, not to a generic role.
  SELECT submitted_by INTO v_prev_owner
  FROM public.submissions
  WHERE work_item_id = p_work_item_id
  ORDER BY submission_number DESC
  LIMIT 1;

  v_prev_owner := COALESCE(v_prev_owner, v_work.owner_id);
  v_deadline   := public.compute_stage_deadline(v_target_id, v_work.priority);

  INSERT INTO public.approvals (work_item_id, stage_id, approver_id, outcome, reason)
  VALUES (p_work_item_id, v_work.current_stage_id, v_actor, 'CHANGES_REQUIRED', p_reason);

  INSERT INTO public.comments (work_item_id, author_id, body, comment_type)
  VALUES (p_work_item_id, v_actor, p_reason, 'CHANGE_REQUEST');

  -- Close any open task at the stage we're leaving
  UPDATE public.tasks
  SET status = 'CANCELLED', closed_at = NOW(), closed_reason = 'Changes requested'
  WHERE work_item_id = p_work_item_id AND closed_at IS NULL;

  IF v_prev_owner IS NOT NULL THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id, v_target_id, v_prev_owner, v_actor,
      format('Revise: %s', v_work.name), p_reason, 'REVISE',
      v_work.priority, v_deadline
    ) RETURNING id INTO v_task_id;
  END IF;

  UPDATE public.work_items
  SET previous_stage_id   = v_work.current_stage_id,
      current_stage_id    = v_target_id,
      current_assignee_id = v_prev_owner,
      pending_with_id     = v_prev_owner,
      pending_with_label  = CASE WHEN v_prev_owner IS NULL THEN 'unassigned' ELSE NULL END,
      status              = 'CHANGES_REQUIRED',
      approval_status     = 'CHANGES_REQUIRED',
      stage_deadline      = v_deadline,
      handoff_at          = NOW(),
      handoff_by          = v_actor
  WHERE id = p_work_item_id;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'CHANGES_REQUESTED',
          v_stage.name, v_target.name, jsonb_build_object('reason', p_reason));

  IF v_prev_owner IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
    VALUES (v_prev_owner, p_work_item_id, v_task_id, 'CHANGES_REQUIRED',
            format('Changes requested: %s', v_work.name), p_reason,
            '/work/' || p_work_item_id);
  END IF;

  RETURN jsonb_build_object(
    'returned_to_stage', v_target.name,
    'assigned_to', v_prev_owner,
    'task_id', v_task_id
  );
END;
$$;

-- ============================================================================
-- put_on_hold / resume
-- ============================================================================
CREATE OR REPLACE FUNCTION public.put_on_hold(
  p_work_item_id UUID,
  p_reason       TEXT,
  p_blocker_type TEXT DEFAULT 'other'
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_work  public.work_items%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required to put work on hold' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  -- The stage is deliberately left untouched so the item resumes where it stopped.
  UPDATE public.work_items
  SET status       = 'ON_HOLD',
      blocker_type = p_blocker_type,
      blocker_note = p_reason
  WHERE id = p_work_item_id;

  UPDATE public.tasks
  SET status = 'ON_HOLD'
  WHERE work_item_id = p_work_item_id AND closed_at IS NULL;

  INSERT INTO public.comments (work_item_id, author_id, body, comment_type)
  VALUES (p_work_item_id, v_actor, p_reason, 'HOLD_REASON');

  INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_actor, 'PUT_ON_HOLD', v_work.status, 'ON_HOLD',
          jsonb_build_object('reason', p_reason, 'blocker_type', p_blocker_type));

  RETURN jsonb_build_object('status', 'ON_HOLD', 'reason', p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.resume_work(
  p_work_item_id UUID
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_work  public.work_items%ROWTYPE;
  v_status TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  v_status := CASE WHEN v_work.current_assignee_id IS NULL THEN 'PENDING' ELSE 'IN_PROGRESS' END;

  UPDATE public.work_items
  SET status = v_status, blocker_type = NULL, blocker_note = NULL
  WHERE id = p_work_item_id;

  UPDATE public.tasks
  SET status = 'PENDING'
  WHERE work_item_id = p_work_item_id AND closed_at IS NULL AND status = 'ON_HOLD';

  INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value)
  VALUES (p_work_item_id, v_actor, 'RESUMED', 'ON_HOLD', v_status);

  RETURN jsonb_build_object('status', v_status);
END;
$$;

-- ============================================================================
-- approve — the forward half of an approval decision
-- ============================================================================
CREATE OR REPLACE FUNCTION public.approve_work_item(
  p_work_item_id UUID,
  p_notes        TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor        UUID := auth.uid();
  v_work         public.work_items%ROWTYPE;
  v_stage        public.workflow_stages%ROWTYPE;
  v_trigger      TEXT;
  v_next_id      UUID;
  v_found        BOOLEAN;
  v_next         public.workflow_stages%ROWTYPE;
  v_assignee     UUID;
  v_deadline     DATE;
  v_task_id      UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;

  INSERT INTO public.approvals (work_item_id, stage_id, approver_id, outcome, reason)
  VALUES (p_work_item_id, v_work.current_stage_id, v_actor, 'APPROVED', p_notes);

  -- An approval stage may still branch on PO.
  v_trigger := public.resolve_submit_trigger(v_work.current_stage_id, v_work.po_required);
  IF v_trigger = 'SUBMISSION' THEN
    v_trigger := 'APPROVED';
  END IF;

  SELECT t.to_stage_id, TRUE INTO v_next_id, v_found
  FROM public.workflow_transitions t
  WHERE t.from_stage_id = v_work.current_stage_id
    AND t.trigger_condition = v_trigger
    AND t.is_active
  LIMIT 1;

  IF NOT COALESCE(v_found, FALSE) THEN
    RAISE EXCEPTION 'No % transition configured out of stage "%"', v_trigger, v_stage.name
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.tasks
  SET status = 'COMPLETED', closed_at = NOW(), closed_reason = 'Approved'
  WHERE work_item_id = p_work_item_id AND assignee_id = v_actor AND closed_at IS NULL;

  IF v_next_id IS NULL THEN
    UPDATE public.work_items
    SET status = 'COMPLETED', approval_status = 'APPROVED',
        previous_stage_id = v_work.current_stage_id,
        current_stage_id = NULL, current_assignee_id = NULL,
        pending_with_id = NULL, pending_with_label = NULL,
        completed_at = NOW()
    WHERE id = p_work_item_id;

    INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value)
    VALUES (p_work_item_id, v_actor, 'APPROVED_AND_COMPLETED', v_stage.name);

    RETURN jsonb_build_object('approved', TRUE, 'completed', TRUE);
  END IF;

  SELECT * INTO v_next FROM public.workflow_stages WHERE id = v_next_id;
  v_assignee := public.resolve_next_assignee(p_work_item_id, v_next_id);
  v_deadline := public.compute_stage_deadline(v_next_id, v_work.priority);

  IF v_assignee IS NOT NULL THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, assigned_by, title,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id, v_next_id, v_assignee, v_actor,
      format('%s — %s', v_work.name, v_next.name),
      CASE WHEN v_next.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END,
      v_work.priority, v_deadline
    ) RETURNING id INTO v_task_id;
  END IF;

  UPDATE public.work_items
  SET previous_stage_id   = v_work.current_stage_id,
      current_stage_id    = v_next_id,
      current_assignee_id = v_assignee,
      pending_with_id     = v_assignee,
      pending_with_label  = CASE WHEN v_assignee IS NULL THEN 'unassigned' ELSE NULL END,
      status              = CASE WHEN v_assignee IS NULL THEN 'PENDING' ELSE 'IN_PROGRESS' END,
      approval_status     = CASE WHEN v_next.requires_approval THEN 'PENDING' ELSE 'APPROVED' END,
      approval_required   = v_next.requires_approval,
      stage_deadline      = v_deadline,
      handoff_at          = NOW(),
      handoff_by          = v_actor
  WHERE id = p_work_item_id;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'APPROVED', v_stage.name, v_next.name,
          jsonb_build_object('trigger', v_trigger, 'notes', p_notes));

  IF v_assignee IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
    VALUES (v_assignee, p_work_item_id, v_task_id, 'ASSIGNMENT',
            format('Approved — now with you: %s', v_work.name),
            format('Stage: %s', v_next.name), '/work/' || p_work_item_id);
  END IF;

  RETURN jsonb_build_object('approved', TRUE, 'completed', FALSE,
                            'to_stage', v_next.name, 'next_assignee_id', v_assignee,
                            'task_id', v_task_id);
END;
$$;


-- ####### 0008_default_workflow.sql #######

-- ============================================================================
-- 0008_default_workflow.sql — the standard workflow, as configuration
-- ============================================================================
-- Built from the stated flow:
--
--   Request -> Brief -> Content -> Design -> Internal Review ->
--   Department Approval -> [Procurement/PO] -> Production ->
--   Final Approval -> Release -> Completed
--
-- and the stated PO rule:
--
--   PO Required = No   : Department Approval -> Production
--   PO Required = Yes  : Department Approval -> PO Request ->
--                        Procurement Review -> PO Approval ->
--                        PO Released -> Production
--
-- WHAT THIS FILE DOES NOT DO, deliberately:
--
--   * No SLAs. sla_days is left NULL on every stage, so the engine sets no
--     deadline rather than inventing one. Suggested durations are in the
--     separate, optional 04_sla_suggested.sql — they are a proposal, not
--     something the source material specified.
--   * No approvers. approval_authorities stays empty. Until rows are added,
--     work reaching an approval stage parks as 'unassigned' and shows up on
--     the Control Tower, which is the correct visible failure rather than a
--     silent assignment to an arbitrary person.
--   * No people. Nothing here names anyone.
-- ============================================================================

INSERT INTO public.workflow_templates (name, description, multi_owner_behavior, is_default)
VALUES (
  'Standard Marketing Workflow',
  'Request through Release, with a conditional procurement detour.',
  'COLLABORATIVE',
  TRUE
)
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      multi_owner_behavior = EXCLUDED.multi_owner_behavior;

-- ----------------------------------------------------------------------------
-- Stages
--
-- expected_role_id maps a stage to a ROLE, never a person, so who actually
-- holds a stage is decided by role assignment at runtime.
-- ----------------------------------------------------------------------------
INSERT INTO public.workflow_stages
  (workflow_id, name, stage_order, description,
   requires_approval, requires_attachment, expected_role_id,
   approval_category, is_terminal)
SELECT
  w.id, v.name, v.ord, v.descr, v.appr, v.attach,
  (SELECT id FROM public.roles WHERE name = v.role),
  v.cat, v.terminal
FROM public.workflow_templates w,
(VALUES
  ('REQUEST',              1,  'Request raised and scoped',
     FALSE, FALSE, 'REQUESTOR',        NULL,        FALSE),
  ('BRIEF',                2,  'Requirements clarified, creator assigned',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('CONTENT',              3,  'Copy and messaging written',
     FALSE, FALSE, 'CREATOR',          NULL,        FALSE),
  ('DESIGN',               4,  'Visual or layout produced',
     FALSE, TRUE,  'CREATOR',          NULL,        FALSE),
  ('INTERNAL_REVIEW',      5,  'Internal QA and brand check',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('DEPARTMENT_APPROVAL',  6,  'Formal departmental sign-off',
     TRUE,  FALSE, 'APPROVER',         'department',FALSE),
  ('PO_REQUEST',           7,  'Purchase order raised with costing',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('PROCUREMENT_REVIEW',   8,  'Procurement checks vendor and cost',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('PO_APPROVAL',          9,  'Purchase order approved',
     TRUE,  FALSE, 'APPROVER',         'po',        FALSE),
  ('PO_RELEASED',         10,  'Purchase order issued to the vendor',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('PRODUCTION',          11,  'Approved work produced or printed',
     FALSE, TRUE,  'VENDOR',           NULL,        FALSE),
  ('FINAL_APPROVAL',      12,  'Sign-off on the finished deliverable',
     TRUE,  FALSE, 'APPROVER',         'final',     FALSE),
  ('RELEASE',             13,  'Published, printed or sent live',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('COMPLETED',           14,  'Closed out',
     FALSE, FALSE, NULL,               NULL,        TRUE)
) AS v(name, ord, descr, appr, attach, role, cat, terminal)
WHERE w.name = 'Standard Marketing Workflow'
ON CONFLICT (workflow_id, name) DO UPDATE
  SET stage_order         = EXCLUDED.stage_order,
      description         = EXCLUDED.description,
      requires_approval   = EXCLUDED.requires_approval,
      requires_attachment = EXCLUDED.requires_attachment,
      expected_role_id    = EXCLUDED.expected_role_id,
      approval_category   = EXCLUDED.approval_category,
      is_terminal         = EXCLUDED.is_terminal;

-- ----------------------------------------------------------------------------
-- Transitions — the edges that make the flow configurable
--
-- Read this block as the whole routing table. Changing how work moves means
-- editing rows here; it never means changing application code.
-- ----------------------------------------------------------------------------
WITH w AS (SELECT id FROM public.workflow_templates WHERE name = 'Standard Marketing Workflow'),
     s AS (SELECT name, id FROM public.workflow_stages
           WHERE workflow_id = (SELECT id FROM w))
INSERT INTO public.workflow_transitions
  (workflow_id, from_stage_id, to_stage_id, trigger_condition, description)
SELECT (SELECT id FROM w),
       (SELECT id FROM s WHERE s.name = e.from_name),
       (SELECT id FROM s WHERE s.name = e.to_name),
       e.trig, e.descr
FROM (VALUES
  -- Forward path
  ('REQUEST',             'BRIEF',              'SUBMISSION',       'Request accepted'),
  ('BRIEF',               'CONTENT',            'SUBMISSION',       'Brief agreed'),
  ('CONTENT',             'DESIGN',             'SUBMISSION',       'Copy ready'),
  ('DESIGN',              'INTERNAL_REVIEW',    'SUBMISSION',       'Design ready for QA'),
  ('INTERNAL_REVIEW',     'DEPARTMENT_APPROVAL','SUBMISSION',       'Passed internal review'),

  -- The PO fork. Both edges leave the same stage; work_items.po_required
  -- decides which one is taken.
  ('DEPARTMENT_APPROVAL', 'PO_REQUEST',         'PO_REQUIRED',      'Approved, procurement needed'),
  ('DEPARTMENT_APPROVAL', 'PRODUCTION',         'NO_PO',            'Approved, no procurement needed'),

  -- Procurement detour
  ('PO_REQUEST',          'PROCUREMENT_REVIEW', 'SUBMISSION',       'PO raised'),
  ('PROCUREMENT_REVIEW',  'PO_APPROVAL',        'SUBMISSION',       'Procurement checked'),
  ('PO_APPROVAL',         'PO_RELEASED',        'APPROVED',         'PO approved'),
  ('PO_RELEASED',         'PRODUCTION',         'SUBMISSION',       'PO issued to vendor'),

  -- Tail
  ('PRODUCTION',          'FINAL_APPROVAL',     'SUBMISSION',       'Production complete'),
  ('FINAL_APPROVAL',      'RELEASE',            'APPROVED',         'Final sign-off given'),
  ('RELEASE',             'COMPLETED',          'SUBMISSION',       'Live'),

  -- Return paths. Each approval gate sends work back to where the fixing
  -- happens, which is what makes "Changes Required" land on the right desk
  -- rather than simply one stage back.
  ('INTERNAL_REVIEW',     'DESIGN',             'CHANGES_REQUIRED', 'QA found problems'),
  ('DEPARTMENT_APPROVAL', 'DESIGN',             'CHANGES_REQUIRED', 'Approver wants changes'),
  ('PO_APPROVAL',         'PO_REQUEST',         'CHANGES_REQUIRED', 'PO needs reworking'),
  ('FINAL_APPROVAL',      'PRODUCTION',         'CHANGES_REQUIRED', 'Final check failed')
) AS e(from_name, to_name, trig, descr)
ON CONFLICT (workflow_id, from_stage_id, trigger_condition) DO UPDATE
  SET to_stage_id = EXCLUDED.to_stage_id,
      description = EXCLUDED.description;

-- ----------------------------------------------------------------------------
-- Deliberately empty: approval_authorities
--
-- Nothing is inserted here because who approves what was never stated. The
-- rows needed look like this — fill in real user ids and run:
--
--   INSERT INTO public.approval_authorities
--     (approver_id, work_category, approval_level, amount_min, amount_max)
--   VALUES
--     ('<user uuid>', 'department', 1, 0, NULL),
--     ('<user uuid>', 'po',         1, 0, 50000),
--     ('<user uuid>', 'po',         2, 50001, NULL),
--     ('<user uuid>', 'final',      1, 0, NULL);
--
-- work_category matches workflow_stages.approval_category above:
-- 'department', 'po' and 'final'. Until at least one row exists per category,
-- work arriving at that gate is parked as unassigned and surfaces on the
-- Control Tower as needing an owner.
-- ----------------------------------------------------------------------------


-- ####### 0009_metrics.sql #######

-- ============================================================================
-- 0009_metrics.sql — Control Tower aggregates
-- ============================================================================
-- One function returning all eight headline counts, so the dashboard makes a
-- single round trip instead of eight.
--
-- SECURITY INVOKER (the default): the counts are computed over exactly the
-- rows the caller is allowed to see. That is why the Control Tower page is
-- restricted to management roles — for a CREATOR, RLS would legitimately
-- narrow these to their own work and the totals would quietly mean something
-- different rather than being empty.
--
-- Each count below has a matching predicate in the /work list page's filters.
-- If one changes, the other must change with it, or a tile will show a number
-- that does not match the rows it opens.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_control_tower_metrics()
RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'active', (
      SELECT COUNT(*) FROM public.v_work_items
      WHERE status NOT IN ('COMPLETED','CANCELLED','REJECTED')
    ),
    'due_today', (
      SELECT COUNT(*) FROM public.v_work_items
      WHERE status NOT IN ('COMPLETED','CANCELLED','REJECTED')
        AND COALESCE(stage_deadline, deadline) = CURRENT_DATE
    ),
    'due_this_week', (
      SELECT COUNT(*) FROM public.v_work_items
      WHERE status NOT IN ('COMPLETED','CANCELLED','REJECTED')
        AND COALESCE(stage_deadline, deadline)
            BETWEEN CURRENT_DATE AND CURRENT_DATE + 7
    ),
    'overdue', (
      SELECT COUNT(*) FROM public.v_work_items WHERE is_overdue
    ),
    'awaiting_approval', (
      SELECT COUNT(*) FROM public.v_work_items
      WHERE approval_required AND approval_status = 'PENDING'
        AND status NOT IN ('COMPLETED','CANCELLED','REJECTED')
    ),
    'po_pending', (
      SELECT COUNT(*) FROM public.v_work_items
      WHERE po_required
        AND po_status NOT IN ('RELEASED','NOT_REQUIRED')
        AND status NOT IN ('COMPLETED','CANCELLED','REJECTED')
    ),
    'blocked', (
      SELECT COUNT(*) FROM public.v_work_items
      WHERE status IN ('BLOCKED','ON_HOLD')
    ),
    'completed', (
      SELECT COUNT(*) FROM public.v_work_items WHERE status = 'COMPLETED'
    ),
    -- Not a headline tile, but the import left 38 rows needing a human
    -- decision; surfacing the count is the only way anyone will work through
    -- them.
    'needs_review', (
      SELECT COUNT(*) FROM public.v_work_items WHERE needs_review
    ),
    'unassigned', (
      SELECT COUNT(*) FROM public.v_work_items
      WHERE current_assignee_id IS NULL
        AND status NOT IN ('COMPLETED','CANCELLED','REJECTED')
    )
  );
$$;

-- ----------------------------------------------------------------------------
-- Breakdowns. Returned as rows rather than JSON so the page can order and
-- slice them without parsing.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_work_by_stage()
RETURNS TABLE (stage_name TEXT, stage_order INT, work_count BIGINT)
LANGUAGE sql STABLE AS $$
  SELECT w.stage_name, w.stage_order, COUNT(*)
  FROM public.v_work_items w
  WHERE w.status NOT IN ('COMPLETED','CANCELLED','REJECTED')
    AND w.stage_name IS NOT NULL
  GROUP BY w.stage_name, w.stage_order
  ORDER BY w.stage_order;
$$;

CREATE OR REPLACE FUNCTION public.get_work_by_owner()
RETURNS TABLE (owner_name TEXT, owner_id UUID, work_count BIGINT, overdue_count BIGINT)
LANGUAGE sql STABLE AS $$
  SELECT
    COALESCE(w.assignee_name, w.owner_name, 'Unassigned'),
    COALESCE(w.current_assignee_id, w.owner_id),
    COUNT(*),
    COUNT(*) FILTER (WHERE w.is_overdue)
  FROM public.v_work_items w
  WHERE w.status NOT IN ('COMPLETED','CANCELLED','REJECTED')
  GROUP BY 1, 2
  ORDER BY 3 DESC;
$$;

-- Who is sitting on approvals, and for how long. "Bottleneck" here means the
-- work has been waiting at an approval gate — measured from the last handoff,
-- which is when it actually landed on that person's desk.
CREATE OR REPLACE FUNCTION public.get_approval_bottlenecks()
RETURNS TABLE (
  pending_with TEXT, work_count BIGINT,
  oldest_days INT, overdue_count BIGINT
) LANGUAGE sql STABLE AS $$
  SELECT
    COALESCE(w.pending_with, 'Unassigned'),
    COUNT(*),
    MAX(GREATEST(0, (CURRENT_DATE - wi.handoff_at::DATE)))::INT,
    COUNT(*) FILTER (WHERE w.is_overdue)
  FROM public.v_work_items w
  JOIN public.work_items wi ON wi.id = w.id
  WHERE w.approval_required
    AND w.approval_status = 'PENDING'
    AND w.status NOT IN ('COMPLETED','CANCELLED','REJECTED')
  GROUP BY 1
  ORDER BY 2 DESC;
$$;

CREATE OR REPLACE FUNCTION public.get_po_bottlenecks()
RETURNS TABLE (po_status TEXT, work_count BIGINT, overdue_count BIGINT)
LANGUAGE sql STABLE AS $$
  SELECT w.po_status, COUNT(*), COUNT(*) FILTER (WHERE w.is_overdue)
  FROM public.v_work_items w
  WHERE w.po_required
    AND w.po_status NOT IN ('RELEASED','NOT_REQUIRED')
    AND w.status NOT IN ('COMPLETED','CANCELLED','REJECTED')
  GROUP BY 1
  ORDER BY 2 DESC;
$$;


-- ####### 0010_repair_users_identity.sql #######

-- ============================================================================
-- 0010_repair_users_identity.sql — bring an EXISTING database up to date
-- ============================================================================
-- 0001 defines public.users with `CREATE TABLE IF NOT EXISTS`, which creates
-- the table correctly on a fresh database and does NOTHING on one that already
-- has it. So the change in 0001 that removed the foreign key to auth.users and
-- gave `id` its own default never reached any database created before that
-- change: re-running the schema looked successful and altered nothing.
--
-- The visible symptom was the seed failing with
--   null value in column "id" of relation "users" violates not-null constraint
-- and, because the seed aborted, an application with no data in it at all.
--
-- This file performs the same change as an ALTER, so it converges an old
-- database on the current shape. It is a no-op on a new one.
-- ============================================================================

-- `id` must generate its own value: people imported from the job list are not
-- login accounts and have no auth.users row to take an id from.
ALTER TABLE public.users ALTER COLUMN id SET DEFAULT gen_random_uuid();

-- Drop the foreign key to auth.users if this database still carries it.
-- Looked up by catalog rather than by name because the name was never
-- specified explicitly and Postgres generated it.
DO $$
DECLARE
  v_constraint TEXT;
BEGIN
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.users'::regclass
    AND contype  = 'f'
    AND confrelid = 'auth.users'::regclass
  LIMIT 1;

  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.users DROP CONSTRAINT %I', v_constraint);
    RAISE NOTICE 'Dropped % — public.users no longer requires an auth account.', v_constraint;
  END IF;
END $$;


-- ####### 0011_sharda_team.sql #######

-- ============================================================================
-- 0011_sharda_team.sql — the real team, roles and approval chain
-- ============================================================================
-- Stated by the team lead:
--
--   Jaggi, Vivek, Love     designers
--   Vidisha                Canva designer
--   Indu                   social media manager
--   Vijaya                 senior content writer
--   Sushant, Nirmal        managers of the team
--   Parul                  gives the final go-ahead
--
-- and the process:
--
--   discussion with leadership / doctors -> content -> creative design
--   -> approval from Sushant and Nirmal -> Parul -> (PO where needed)
--   -> production -> release
--
-- Everything here is DATA. Changing who approves what, or who holds a stage,
-- is an UPDATE to these tables — never a code change or a deploy.
--
-- ONE ASSUMPTION, flagged rather than hidden:
--   "approval from sushant and nirmal" is read as EITHER manager approving,
--   not both in sequence. Both are registered at approval_level 1, and the
--   engine takes the first match. To require BOTH, set one of them to
--   approval_level 2 — the engine will then route to level 1, and on approval
--   to level 2. See the note at the foot of this file.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Roles for the actual disciplines
-- ----------------------------------------------------------------------------
INSERT INTO public.roles (name, description, permissions) VALUES
  ('CONTENT_WRITER', 'Writes copy and messaging',
   '["view_own","submit_work","upload_files","add_comments"]'),
  ('DESIGNER', 'Creates artwork and layouts',
   '["view_own","submit_work","upload_files","add_comments"]'),
  ('SOCIAL_MEDIA', 'Publishes and schedules social content',
   '["view_own","submit_work","upload_files","add_comments"]'),
  ('MANAGER', 'Approves team output and reassigns work',
   '["view_all","approve_work","request_changes","reassign_work","modify_deadlines","assign_work","view_reports"]'),
  ('FINAL_APPROVER', 'Gives the final go-ahead before release',
   '["view_all","approve_work","request_changes","add_comments"]')
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      permissions = EXCLUDED.permissions;

-- ----------------------------------------------------------------------------
-- People
--
-- All nine are created here, not only the ones new to the job list. The role
-- assignments below match on full_name, so if this migration relied on the
-- import having run it would silently assign nothing on a database where it
-- had not — leaving a team with no roles and an engine with nobody to route
-- to, with no error to explain it.
--
-- The emails match the pattern the import uses, so ON CONFLICT (email)
-- deduplicates rather than creating a second row for the same person. They
-- stay @placeholder.invalid because no real addresses were given; inventing
-- them would put wrong data in a field that looks authoritative. These are
-- people, not logins — see 0001 on why nothing is written to auth.users.
-- ----------------------------------------------------------------------------
INSERT INTO public.users (email, full_name) VALUES
  ('jaggi@placeholder.invalid',   'Jaggi'),
  ('vivek@placeholder.invalid',   'Vivek'),
  ('love@placeholder.invalid',    'Love'),
  ('vidisha@placeholder.invalid', 'Vidisha'),
  ('indu@placeholder.invalid',    'Indu'),
  ('vijaya@placeholder.invalid',  'Vijaya'),
  ('sushant@placeholder.invalid', 'Sushant'),
  ('nirmal@placeholder.invalid',  'Nirmal'),
  ('parul@placeholder.invalid',   'Parul')
ON CONFLICT (email) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Who is what
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_person TEXT;
  v_role   TEXT;
  v_pairs  TEXT[][] := ARRAY[
    ['Jaggi',   'DESIGNER'],
    ['Vivek',   'DESIGNER'],
    ['Love',    'DESIGNER'],
    ['Vidisha', 'DESIGNER'],        -- Canva specifically; same stage, noted below
    ['Indu',    'SOCIAL_MEDIA'],
    ['Vijaya',  'CONTENT_WRITER'],
    ['Sushant', 'MANAGER'],
    ['Nirmal',  'MANAGER'],
    ['Parul',   'FINAL_APPROVER']
  ];
BEGIN
  FOR i IN 1 .. array_length(v_pairs, 1) LOOP
    v_person := v_pairs[i][1];
    v_role   := v_pairs[i][2];

    INSERT INTO public.user_roles (user_id, role_id)
    SELECT u.id, r.id
    FROM public.users u, public.roles r
    WHERE u.full_name = v_person AND r.name = v_role
    ON CONFLICT (user_id, role_id) DO NOTHING;
  END LOOP;

  -- Managers also need APPROVER so the approval gates can route to them, and
  -- COORDINATOR so they can create and assign work.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT u.id, r.id FROM public.users u, public.roles r
  WHERE u.full_name IN ('Sushant','Nirmal') AND r.name IN ('APPROVER','COORDINATOR')
  ON CONFLICT (user_id, role_id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role_id)
  SELECT u.id, r.id FROM public.users u, public.roles r
  WHERE u.full_name = 'Parul' AND r.name = 'APPROVER'
  ON CONFLICT (user_id, role_id) DO NOTHING;
END $$;

-- Vidisha works in Canva rather than the design suite. The distinction matters
-- when choosing who to hand a piece of work to, but not to the workflow, so it
-- is recorded on the person instead of becoming a separate stage.
UPDATE public.users SET phone = phone WHERE FALSE;  -- no-op, keeps this block readable
COMMENT ON COLUMN public.users.full_name IS
  'Display name. Discipline detail (e.g. Vidisha works in Canva) lives in user_roles plus this note rather than in a separate stage.';

-- ----------------------------------------------------------------------------
-- The approval chain — the part that was empty before
-- ----------------------------------------------------------------------------
-- department : Sushant or Nirmal
-- final      : Parul
-- po         : Sushant or Nirmal (no separate procurement approver was named)
-- ----------------------------------------------------------------------------
INSERT INTO public.approval_authorities (approver_id, work_category, approval_level)
SELECT u.id, c.category, 1
FROM public.users u
JOIN (VALUES
  ('Sushant','department'), ('Nirmal','department'),
  ('Parul',  'final'),
  ('Sushant','po'),         ('Nirmal','po')
) AS c(person, category) ON c.person = u.full_name
WHERE NOT EXISTS (
  SELECT 1 FROM public.approval_authorities a
  WHERE a.approver_id = u.id AND a.work_category = c.category
);

-- ============================================================================
-- To require BOTH managers rather than either:
--
--   UPDATE public.approval_authorities SET approval_level = 2
--   WHERE work_category = 'department'
--     AND approver_id = (SELECT id FROM public.users WHERE full_name = 'Nirmal');
--
-- and add a second approval stage to the workflow. As it stands the engine
-- routes to the lowest active level and one approval clears the gate.
-- ============================================================================


-- ####### 0012_sharda_workflow.sql #######

-- ============================================================================
-- 0012_sharda_workflow.sql — the process the team actually follows
-- ============================================================================
--   discussion with leadership / doctors
--     -> content (Vijaya)
--     -> creative design (Jaggi / Vivek / Love / Vidisha)
--     -> back to Vijaya, who reviews EVERYTHING
--     -> Sushant or Nirmal
--     -> Parul's final go-ahead
--     -> PO where one is needed
--     -> production -> Indu posts it on social media
--
-- Every stage points at a ROLE, never a person, so who holds a stage is
-- decided by role assignment in 0011 and changes without touching this file.
-- ============================================================================

-- idx_workflow_templates_one_default permits exactly one default, so the
-- previous holder must be cleared BEFORE this one is inserted -- not after,
-- which is a unique violation.
UPDATE public.workflow_templates SET is_default = FALSE
WHERE is_default AND name <> 'Sharda Marketing Workflow';

INSERT INTO public.workflow_templates (name, description, multi_owner_behavior, is_default)
VALUES (
  'Sharda Marketing Workflow',
  'Leadership brief through to live, with Vijaya reviewing everything and a conditional PO detour.',
  'COLLABORATIVE',
  TRUE
)
ON CONFLICT (name) DO UPDATE
  SET description          = EXCLUDED.description,
      multi_owner_behavior = EXCLUDED.multi_owner_behavior,
      is_default           = TRUE;

-- ----------------------------------------------------------------------------
-- Stages
-- ----------------------------------------------------------------------------
-- Shifted out of the way first so the fixed-position upsert below can never
-- collide with a stage a LATER migration inserted at one of these same
-- numbers -- CONCEPT, added in 0017_creative_chain.sql, sits at stage_order 2.
-- Without this, a second run of the full bundle resets every known stage back
-- to this migration's own numbering (which does not know CONCEPT exists) and
-- collides with that leftover row before 0017 gets a chance to run again and
-- fix it. Mirrors the same shift-then-set idiom 0017 uses for its own insert.
UPDATE public.workflow_stages
   SET stage_order = stage_order + 1000
 WHERE workflow_id = (SELECT id FROM public.workflow_templates WHERE name = 'Sharda Marketing Workflow');

INSERT INTO public.workflow_stages
  (workflow_id, name, stage_order, description,
   requires_approval, requires_attachment, expected_role_id, approval_category, is_terminal)
SELECT w.id, v.name, v.ord, v.descr, v.appr, v.attach,
       (SELECT id FROM public.roles WHERE name = v.role),
       v.cat, v.terminal
FROM public.workflow_templates w,
(VALUES
  ('LEADERSHIP_BRIEF',   1, 'Discussion with leadership or the requesting doctor; scope agreed',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('CONTENT',            2, 'Copy and messaging written',
     FALSE, FALSE, 'CONTENT_WRITER', NULL,         FALSE),
  ('DESIGN',             3, 'Artwork and layout produced',
     FALSE, TRUE,  'DESIGNER',       NULL,         FALSE),
  ('CONTENT_REVIEW',     4, 'Vijaya reviews the finished piece before it goes up the chain',
     FALSE, FALSE, 'CONTENT_WRITER', NULL,         FALSE),
  ('MANAGER_APPROVAL',   5, 'Sushant or Nirmal signs off',
     TRUE,  FALSE, 'APPROVER',       'department', FALSE),
  ('FINAL_APPROVAL',     6, 'Parul gives the final go-ahead',
     TRUE,  FALSE, 'APPROVER',       'final',      FALSE),
  ('PO_REQUEST',         7, 'Purchase order raised with costing',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('PROCUREMENT_REVIEW', 8, 'Vendor and cost checked',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('PO_APPROVAL',        9, 'Purchase order approved',
     TRUE,  FALSE, 'APPROVER',       'po',         FALSE),
  ('PO_RELEASED',       10, 'PO issued to the vendor',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('PRODUCTION',        11, 'Printed, produced or built',
     FALSE, TRUE,  'DESIGNER',       NULL,         FALSE),
  -- Indu posts it. Physical work (hoardings, signage, print) also lands here
  -- because no separate owner was named for it; if that turns out wrong it is
  -- one row -- point RELEASE at COORDINATOR, or add a second template.
  ('RELEASE',           12, 'Indu posts it on social media',
     FALSE, FALSE, 'SOCIAL_MEDIA',   NULL,         FALSE),
  ('COMPLETED',         13, 'Closed out',
     FALSE, FALSE, NULL,             NULL,         TRUE)
) AS v(name, ord, descr, appr, attach, role, cat, terminal)
WHERE w.name = 'Sharda Marketing Workflow'
ON CONFLICT (workflow_id, name) DO UPDATE
  SET stage_order         = EXCLUDED.stage_order,
      description         = EXCLUDED.description,
      requires_approval   = EXCLUDED.requires_approval,
      requires_attachment = EXCLUDED.requires_attachment,
      expected_role_id    = EXCLUDED.expected_role_id,
      approval_category   = EXCLUDED.approval_category,
      is_terminal         = EXCLUDED.is_terminal;

-- ----------------------------------------------------------------------------
-- Transitions — the whole routing table
-- ----------------------------------------------------------------------------
WITH w AS (SELECT id FROM public.workflow_templates WHERE name = 'Sharda Marketing Workflow'),
     s AS (SELECT name, id FROM public.workflow_stages WHERE workflow_id = (SELECT id FROM w))
INSERT INTO public.workflow_transitions
  (workflow_id, from_stage_id, to_stage_id, trigger_condition, description)
SELECT (SELECT id FROM w),
       (SELECT id FROM s WHERE s.name = e.from_name),
       (SELECT id FROM s WHERE s.name = e.to_name),
       e.trig, e.descr
FROM (VALUES
  ('LEADERSHIP_BRIEF',   'CONTENT',            'SUBMISSION',       'Brief agreed'),
  ('CONTENT',            'DESIGN',             'SUBMISSION',       'Copy ready'),
  ('DESIGN',             'CONTENT_REVIEW',     'SUBMISSION',       'Design ready for Vijaya'),
  ('CONTENT_REVIEW',     'MANAGER_APPROVAL',   'SUBMISSION',       'Vijaya passed it'),
  ('MANAGER_APPROVAL',   'FINAL_APPROVAL',     'APPROVED',         'Manager signed off'),

  -- Parul's decision forks on whether money needs committing.
  ('FINAL_APPROVAL',     'PO_REQUEST',         'PO_REQUIRED',      'Approved, purchase order needed'),
  ('FINAL_APPROVAL',     'PRODUCTION',         'NO_PO',            'Approved, no purchase order needed'),

  ('PO_REQUEST',         'PROCUREMENT_REVIEW', 'SUBMISSION',       'PO raised'),
  ('PROCUREMENT_REVIEW', 'PO_APPROVAL',        'SUBMISSION',       'Vendor and cost checked'),
  ('PO_APPROVAL',        'PO_RELEASED',        'APPROVED',         'PO approved'),
  ('PO_RELEASED',        'PRODUCTION',         'SUBMISSION',       'PO issued'),

  ('PRODUCTION',         'RELEASE',            'SUBMISSION',       'Produced'),
  ('RELEASE',            'COMPLETED',          'SUBMISSION',       'Live'),

  -- Rejections go back to where the fix happens, not simply one stage back.
  -- All three approval gates sit AFTER design, so the work returns there.
  ('CONTENT_REVIEW',     'DESIGN',             'CHANGES_REQUIRED', 'Vijaya wants changes'),
  ('MANAGER_APPROVAL',   'DESIGN',             'CHANGES_REQUIRED', 'Manager wants changes'),
  ('FINAL_APPROVAL',     'DESIGN',             'CHANGES_REQUIRED', 'Parul wants changes'),
  ('PO_APPROVAL',        'PO_REQUEST',         'CHANGES_REQUIRED', 'PO needs reworking')
) AS e(from_name, to_name, trig, descr)
ON CONFLICT (workflow_id, from_stage_id, trigger_condition) DO UPDATE
  SET to_stage_id = EXCLUDED.to_stage_id,
      description = EXCLUDED.description;

-- No SLAs. No turnaround times were stated, and compute_stage_deadline leaves
-- the deadline NULL rather than inventing one. To add them:
--   INSERT INTO public.stage_sla_config (stage_id, priority, sla_days) ...


-- ####### 0013_admin_task_controls.sql #######

-- ============================================================================
-- 0013_admin_task_controls.sql — manual reassignment and task removal
-- ============================================================================
-- The audit that reviewed this app flagged a real gap: work_items_update
-- already lets ADMIN/WORKFLOW_MANAGER edit any work item, tasks_delete already
-- lets ADMIN delete any task, and the MANAGER role has carried the
-- 'reassign_work' permission since 0001 -- but nothing in the application
-- actually called these. The only way to move a person's work off them, or
-- correct a wrongly-created task, was a WORKFLOW_MANAGER editing rows by hand
-- in the Supabase table editor.
--
-- Same discipline as 0007_handoff.sql: a manual reassignment touches tasks,
-- work_items, activity_log and notifications together, so it is one
-- SECURITY INVOKER function rather than several round trips from the client
-- that could half-apply. SECURITY INVOKER means RLS still applies -- the role
-- check below is a friendlier error message, not the boundary; a caller
-- without the role gets refused by the GRANT/policy regardless.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- reassign_work_item — move the current stage to a different person.
--
-- This is an override of the normal handoff, not a thing the current holder
-- does to themselves (that is submit_for_next_stage). It works whether or not
-- anyone currently holds the item, which is what makes it double as the fix
-- for the 20-odd imported items with no assignee: opening one and reassigning
-- it puts a real task in the new owner's queue exactly as if the engine had
-- routed it there.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reassign_work_item(
  p_work_item_id     UUID,
  p_new_assignee_id  UUID,
  p_note             TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor              UUID := auth.uid();
  v_work               public.work_items%ROWTYPE;
  v_stage              public.workflow_stages%ROWTYPE;
  v_old_assignee_name  TEXT;
  v_new_assignee_name  TEXT;
  v_deadline           DATE;
  v_task_id            UUID;
  v_action_type        TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']) THEN
    RAISE EXCEPTION 'Only an admin or workflow manager can reassign work' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot be reassigned', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before reassigning.'
      USING ERRCODE = '22023';
  END IF;

  IF v_work.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = p_new_assignee_id AND is_active
  ) THEN
    RAISE EXCEPTION 'That person is not a known, active user' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;

  SELECT full_name INTO v_old_assignee_name
  FROM public.users WHERE id = v_work.current_assignee_id;
  SELECT full_name INTO v_new_assignee_name
  FROM public.users WHERE id = p_new_assignee_id;

  -- Close whatever open task(s) currently represent this stage. Usually one,
  -- but PARALLEL/SEQUENTIAL work can have more than one collaborator holding
  -- an open task at the same stage.
  UPDATE public.tasks
  SET status = 'CANCELLED', closed_at = NOW(),
      closed_reason = format('Reassigned to %s%s',
                              v_new_assignee_name,
                              CASE WHEN p_note IS NOT NULL THEN ': ' || p_note ELSE '' END)
  WHERE work_item_id = p_work_item_id
    AND stage_id = v_work.current_stage_id
    AND closed_at IS NULL;

  v_deadline    := public.compute_stage_deadline(v_work.current_stage_id, v_work.priority);
  v_action_type := CASE WHEN v_stage.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END;

  INSERT INTO public.tasks (
    work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
    action_type, priority, due_date
  ) VALUES (
    p_work_item_id, v_work.current_stage_id, p_new_assignee_id, v_actor,
    format('%s — %s', v_work.name, v_stage.name), p_note,
    v_action_type, v_work.priority, v_deadline
  ) RETURNING id INTO v_task_id;

  UPDATE public.work_items
  SET current_assignee_id = p_new_assignee_id,
      pending_with_id     = p_new_assignee_id,
      pending_with_label  = NULL,
      status              = 'IN_PROGRESS',
      stage_deadline      = v_deadline,
      handoff_at          = NOW(),
      handoff_by          = v_actor
  WHERE id = p_work_item_id;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'REASSIGNED',
          COALESCE(v_old_assignee_name, 'unassigned'), v_new_assignee_name,
          jsonb_build_object('note', p_note));

  INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
  VALUES (p_new_assignee_id, p_work_item_id, v_task_id, 'ASSIGNMENT',
          format('Reassigned to you: %s', v_work.name),
          format('Stage: %s.%s', v_stage.name,
                 CASE WHEN p_note IS NOT NULL THEN ' ' || p_note ELSE '' END),
          '/work/' || p_work_item_id);

  RETURN jsonb_build_object(
    'reassigned', TRUE,
    'stage', v_stage.name,
    'new_assignee_id', p_new_assignee_id,
    'new_assignee_name', v_new_assignee_name,
    'task_id', v_task_id
  );
END;
$$;

-- ----------------------------------------------------------------------------
-- add_task_to_work_item — hand someone a task without disturbing whoever
-- already holds the stage.
--
-- Distinct from reassign_work_item on purpose: reassign REPLACES the current
-- holder (closes their task, opens one for the new person). This ADDS one --
-- a helper, a second pair of eyes, someone who needs visibility -- so an
-- existing open task is left exactly as it was. On a currently-unassigned
-- item there is nothing to leave alone, so this one new task also becomes
-- the item's official handoff, same as reassign_work_item would.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_task_to_work_item(
  p_work_item_id UUID,
  p_assignee_id  UUID,
  p_note         TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor         UUID := auth.uid();
  v_work          public.work_items%ROWTYPE;
  v_stage         public.workflow_stages%ROWTYPE;
  v_assignee_name TEXT;
  v_deadline      DATE;
  v_task_id       UUID;
  v_action_type   TEXT;
  v_had_holder    BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']) THEN
    RAISE EXCEPTION 'Only an admin or workflow manager can add a task' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot take a new task', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before adding a task.'
      USING ERRCODE = '22023';
  END IF;

  IF v_work.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = p_assignee_id AND is_active
  ) THEN
    RAISE EXCEPTION 'That person is not a known, active user' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.tasks
    WHERE work_item_id = p_work_item_id AND assignee_id = p_assignee_id
      AND stage_id = v_work.current_stage_id AND closed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'This person already has an open task at this stage' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;
  SELECT full_name INTO v_assignee_name FROM public.users WHERE id = p_assignee_id;

  v_deadline    := public.compute_stage_deadline(v_work.current_stage_id, v_work.priority);
  v_action_type := CASE WHEN v_stage.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END;

  INSERT INTO public.tasks (
    work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
    action_type, priority, due_date
  ) VALUES (
    p_work_item_id, v_work.current_stage_id, p_assignee_id, v_actor,
    format('%s — %s', v_work.name, v_stage.name), p_note,
    v_action_type, v_work.priority, v_deadline
  ) RETURNING id INTO v_task_id;

  v_had_holder := v_work.current_assignee_id IS NOT NULL;

  IF NOT v_had_holder THEN
    UPDATE public.work_items
    SET current_assignee_id = p_assignee_id,
        pending_with_id     = p_assignee_id,
        pending_with_label  = NULL,
        status              = 'IN_PROGRESS',
        stage_deadline      = v_deadline,
        handoff_at          = NOW(),
        handoff_by          = v_actor
    WHERE id = p_work_item_id;
  END IF;

  -- Whoever gets a task should show up as a collaborator, which is what the
  -- Work Detail page's "Collaborators" field actually reads from.
  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role, assigned_by)
  VALUES (p_work_item_id, p_assignee_id, 'SUPPORT', v_actor)
  ON CONFLICT (work_item_id, user_id) DO NOTHING;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'TASK_ADDED', v_assignee_name,
          jsonb_build_object('note', p_note, 'stage', v_stage.name));

  INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
  VALUES (p_assignee_id, p_work_item_id, v_task_id, 'ASSIGNMENT',
          format('New task: %s', v_work.name),
          format('Stage: %s.%s', v_stage.name,
                 CASE WHEN p_note IS NOT NULL THEN ' ' || p_note ELSE '' END),
          '/work/' || p_work_item_id);

  RETURN jsonb_build_object(
    'added', TRUE,
    'task_id', v_task_id,
    'assignee_name', v_assignee_name,
    'became_holder', NOT v_had_holder
  );
END;
$$;

-- ----------------------------------------------------------------------------
-- remove_task — delete a task outright rather than closing it through a
-- normal handoff. Matches tasks_delete RLS exactly (ADMIN only): this is for
-- correcting a mistake (duplicate task, wrong person, imported cruft), not a
-- workflow action, so it does not appear in anyone's activity as a handoff --
-- just a TASK_REMOVED entry recording that it happened and why.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_task(
  p_task_id UUID,
  p_reason  TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor     UUID := auth.uid();
  v_task      public.tasks%ROWTYPE;
  v_remaining INT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.has_role(ARRAY['ADMIN']) THEN
    RAISE EXCEPTION 'Only an admin can delete a task' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_task.closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This task is already closed' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
  VALUES (v_task.work_item_id, v_actor, 'TASK_REMOVED',
          jsonb_build_object('title', v_task.title, 'assignee_id', v_task.assignee_id,
                             'reason', p_reason));

  DELETE FROM public.tasks WHERE id = p_task_id;

  -- If nothing else has an open task on this work item, "Pending With" must
  -- say so honestly rather than keep pointing at someone whose task no longer
  -- exists.
  SELECT COUNT(*) INTO v_remaining
  FROM public.tasks
  WHERE work_item_id = v_task.work_item_id AND closed_at IS NULL;

  IF v_remaining = 0 THEN
    UPDATE public.work_items
    SET current_assignee_id = NULL,
        pending_with_id     = NULL,
        pending_with_label  = 'unassigned',
        status              = CASE
                                 WHEN status IN ('ON_HOLD','COMPLETED','CANCELLED','REJECTED')
                                 THEN status ELSE 'PENDING' END
    WHERE id = v_task.work_item_id;
  END IF;

  RETURN jsonb_build_object(
    'removed', TRUE,
    'work_item_id', v_task.work_item_id,
    'cleared_assignment', v_remaining = 0
  );
END;
$$;


-- ####### 0014_po_not_assessed.sql #######

-- ============================================================================
-- 0014_po_not_assessed.sql — stop silently asserting "PO not required"
-- ============================================================================
-- work_items.po_required defaults to FALSE and po_status defaults to
-- 'NOT_REQUIRED' (0003_work.sql). The seed importer never set either column
-- explicitly, so every imported row fell through to those defaults — which
-- means the app has been claiming, with the same confidence as an item whose
-- source actually said "no PO needed", that a purchase order was considered
-- and ruled out for all 38 imported items. The source document never
-- mentions a purchase order once, for any of them. That is an invented fact,
-- not a read one.
--
-- po_required stays a NOT NULL boolean -- there is no way to make FALSE mean
-- "unknown" without breaking every existing query and RPC that branches on
-- it. po_status can and does distinguish the two: NOT_ASSESSED now means
-- "nobody has said", NOT_REQUIRED keeps meaning "confirmed, no PO needed".
-- ============================================================================

ALTER TABLE public.work_items DROP CONSTRAINT IF EXISTS chk_work_po_status;
ALTER TABLE public.work_items ADD CONSTRAINT chk_work_po_status CHECK (po_status IN (
  'NOT_ASSESSED','NOT_REQUIRED','NOT_STARTED','REQUESTED','IN_REVIEW','APPROVED','RELEASED','REJECTED'
));

-- Backfill only imported rows (source_ref IS NOT NULL) that are still sitting
-- on the untouched default. A work item created through the app has a human
-- who actually ticked or left unticked "a purchase order is needed" -- that
-- is a real decision, not a default, and must not be overwritten.
UPDATE public.work_items
SET po_status = 'NOT_ASSESSED'
WHERE source_ref IS NOT NULL
  AND po_required = FALSE
  AND po_status = 'NOT_REQUIRED';


-- ####### 0015_attachments_tags_status_control.sql #######

-- ============================================================================
-- 0015_attachments_tags_status_control.sql
--   1. Real file attachments (Supabase Storage bucket + policies)
--   2. Free-form tags
--   3. Status changes restricted to named people
--   4. Comment threads: replies, resolve, soft delete
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Stated by the team lead:
--   "each person will get their credential, however only Vijaya and Nirmal
--    can change the status"
--
-- Implemented as a PERMISSION, not a pair of hardcoded names, so adding a
-- third person later is an INSERT rather than a deploy. See the
-- STATUS_CONTROLLER role and public.can_change_status() below.
--
-- ONE JUDGEMENT CALL, flagged rather than hidden:
--
-- Read absolutely literally, "only Vijaya and Nirmal can change the status"
-- also stops a designer handing a finished design to Vijaya — because that
-- moves the work to the next stage. The creative chain the same person
-- described ("designer designs it, then Vijaya proofreads it") then cannot
-- run: every one of the ~38 daily handoffs would need Vijaya or Nirmal to
-- press the button on someone else's behalf, and they become the bottleneck
-- for work they have not looked at yet.
--
-- The same tension appears again one step further on: the chain also says
-- "Nirmal/Sushant verifies, then Parul verifies". Under the literal reading
-- Sushant and Parul could not approve either, which deletes two of the three
-- verification steps.
--
-- So the line is drawn between DOING, JUDGING and CONTROLLING:
--   anyone            — submit my own finished work to the next person
--   the gate's approver — approve, reject or send back AT THEIR OWN GATE
--                         (Vijaya proofread, Sushant/Nirmal, Parul final),
--                         resolved from approval_authorities, not from names
--   V and N only      — hold, resume, cancel, mark complete, move work
--                       backwards outside a verdict, or move work that is
--                       neither theirs nor at their gate
--
-- To enforce the strictest reading instead, so that literally no stage moves
-- without them, one statement does it:
--
--   UPDATE public.roles SET permissions = permissions::jsonb - 'submit_work'
--   WHERE name IN ('CONTENT_WRITER','DESIGNER','SOCIAL_MEDIA','CREATOR');
--
-- and change the last ELSIF below to drop its can_edit_work_item() exception.
-- ============================================================================


-- ============================================================================
-- 1. ATTACHMENTS — storage bucket
-- ============================================================================
-- The `files` table already existed (migration 0004) but nothing ever wrote to
-- it: there was no bucket, so `storage_path` pointed at nowhere. This creates
-- the bucket the column was always describing.
--
-- Private bucket. Nothing is served by public URL; the app mints short-lived
-- signed URLs per download, so a leaked link expires instead of exposing the
-- whole bucket forever.
-- ----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'work-files',
  'work-files',
  FALSE,
  26214400,  -- 25 MB. Raise here, and in MAX_FILE_BYTES in src/lib/files.ts.
  ARRAY[
    'application/pdf',
    'image/jpeg','image/png','image/gif','image/webp','image/svg+xml','image/heic',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'text/plain','text/csv',
    'application/zip','application/x-zip-compressed',
    'video/mp4','video/quicktime'
  ]
)
ON CONFLICT (id) DO UPDATE
  SET file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types,
      public             = FALSE;


-- ----------------------------------------------------------------------------
-- Storage policies
--
-- Object names are laid out as `<work_item_id>/<uuid>-<filename>`, so the first
-- path segment identifies the work item. can_see_work_item() then answers the
-- only question that matters: may this person see that item at all? Permission
-- on the file is therefore never stored twice — it is always derived from the
-- work item, and cannot drift out of step with it.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS work_files_select ON storage.objects;
CREATE POLICY work_files_select ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'work-files'
    AND public.can_see_work_item(
      NULLIF((storage.foldername(name))[1], '')::UUID
    )
  );

DROP POLICY IF EXISTS work_files_insert ON storage.objects;
CREATE POLICY work_files_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'work-files'
    AND public.can_see_work_item(
      NULLIF((storage.foldername(name))[1], '')::UUID
    )
  );

-- Deliberately narrower than insert: anyone who can see the item may attach a
-- file, but only the uploader or a manager may remove one. Someone else's
-- evidence is not yours to delete.
DROP POLICY IF EXISTS work_files_delete ON storage.objects;
CREATE POLICY work_files_delete ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'work-files'
    AND (
      owner = auth.uid()
      OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER'])
    )
  );


-- ----------------------------------------------------------------------------
-- files: allow soft delete by uploader or manager, and hard delete by admin.
-- The 0006 update policy already covers the soft-delete path; this adds the
-- managers introduced in 0011, who were not a role when 0006 was written.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS files_update ON public.files;
CREATE POLICY files_update ON public.files FOR UPDATE TO authenticated
  USING (uploaded_by = auth.uid()
         OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']))
  WITH CHECK (uploaded_by = auth.uid()
         OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']));

-- An uploaded_by default means the column cannot be spoofed from the client.
ALTER TABLE public.files
  ALTER COLUMN uploaded_by SET DEFAULT auth.uid();

CREATE INDEX IF NOT EXISTS idx_files_storage_path ON public.files(storage_path);


-- ============================================================================
-- 2. TAGS — free-form, created on the fly
-- ============================================================================
-- Free-form was chosen over a fixed vocabulary, so the guard against
-- "Hoarding" / "hoardings" / "HOARDING" becoming three tags is a normalised
-- unique key rather than an admin. `slug` is the identity; `label` is whatever
-- the first person typed, and is what gets displayed.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tags (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       TEXT NOT NULL UNIQUE,
  label      TEXT NOT NULL,
  colour     TEXT NOT NULL DEFAULT 'slate',
  created_by UUID REFERENCES public.users(id) DEFAULT auth.uid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_tag_label_len CHECK (char_length(label) BETWEEN 1 AND 40),
  CONSTRAINT chk_tag_slug_shape CHECK (slug ~ '^[a-z0-9][a-z0-9 -]*$')
);

COMMENT ON COLUMN public.tags.slug IS
  'Lowercased, collapsed-whitespace form of label. The uniqueness key, so the
   same tag typed three different ways resolves to one row.';

CREATE TABLE IF NOT EXISTS public.work_item_tags (
  work_item_id UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  tag_id       UUID NOT NULL REFERENCES public.tags(id) ON DELETE CASCADE,
  added_by     UUID REFERENCES public.users(id) DEFAULT auth.uid(),
  added_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (work_item_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_work_item_tags_tag ON public.work_item_tags(tag_id);

ALTER TABLE public.tags           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_item_tags ENABLE ROW LEVEL SECURITY;

-- The tag vocabulary is not secret: everyone signed in can read and extend it.
-- What a tag is ATTACHED to is scoped to the work item, below.
DROP POLICY IF EXISTS tags_select ON public.tags;
CREATE POLICY tags_select ON public.tags FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS tags_insert ON public.tags;
CREATE POLICY tags_insert ON public.tags FOR INSERT TO authenticated WITH CHECK (TRUE);

-- Renaming or recolouring a tag changes it everywhere it is used, so that stays
-- with managers even though creating one does not.
DROP POLICY IF EXISTS tags_update ON public.tags;
CREATE POLICY tags_update ON public.tags FOR UPDATE TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']))
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']));

DROP POLICY IF EXISTS tags_delete ON public.tags;
CREATE POLICY tags_delete ON public.tags FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN']));

DROP POLICY IF EXISTS work_item_tags_select ON public.work_item_tags;
CREATE POLICY work_item_tags_select ON public.work_item_tags FOR SELECT TO authenticated
  USING (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS work_item_tags_insert ON public.work_item_tags;
CREATE POLICY work_item_tags_insert ON public.work_item_tags FOR INSERT TO authenticated
  WITH CHECK (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS work_item_tags_delete ON public.work_item_tags;
CREATE POLICY work_item_tags_delete ON public.work_item_tags FOR DELETE TO authenticated
  USING (public.can_see_work_item(work_item_id));


-- ----------------------------------------------------------------------------
-- Attach a tag by the text someone typed, creating it if new.
--
-- Doing this in one SQL function rather than a read-then-write in the app
-- closes the race where two people add the same new tag at the same moment and
-- the second gets a unique violation instead of a tag.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.attach_tag(p_work_item_id UUID, p_label TEXT)
RETURNS UUID
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v_label TEXT := btrim(regexp_replace(p_label, '\s+', ' ', 'g'));
  v_slug  TEXT := lower(btrim(regexp_replace(p_label, '\s+', ' ', 'g')));
  v_id    UUID;
BEGIN
  IF v_label = '' THEN
    RAISE EXCEPTION 'A tag needs a name' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_label) > 40 THEN
    RAISE EXCEPTION 'Tag names are limited to 40 characters' USING ERRCODE = '22023';
  END IF;
  IF v_slug !~ '^[a-z0-9][a-z0-9 -]*$' THEN
    RAISE EXCEPTION 'Tags may use letters, numbers, spaces and hyphens only'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.tags (slug, label)
  VALUES (v_slug, v_label)
  ON CONFLICT (slug) DO UPDATE SET slug = EXCLUDED.slug  -- no-op, to get the id back
  RETURNING id INTO v_id;

  INSERT INTO public.work_item_tags (work_item_id, tag_id)
  VALUES (p_work_item_id, v_id)
  ON CONFLICT DO NOTHING;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.attach_tag(UUID, TEXT) TO authenticated;


-- ============================================================================
-- 3. STATUS CONTROL — only named people may move work
-- ============================================================================
-- Everyone gets a login and can do the day-to-day: see their work, attach
-- files, tag, comment. Advancing a stage, approving, holding, resuming or
-- editing status is reserved.
--
-- Expressed as the permission `change_status`. To let someone else do it,
-- give them the STATUS_CONTROLLER role — no code change, no deploy.
-- ----------------------------------------------------------------------------
INSERT INTO public.roles (name, description, permissions) VALUES
  ('STATUS_CONTROLLER',
   'May move work between stages and change its status',
   '["change_status","view_all","submit_work","approve_work","request_changes","reassign_work","modify_deadlines","view_reports"]')
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      permissions = EXCLUDED.permissions;

-- The disciplines KEEP submit_work. Handing your own finished work to the next
-- person is not a status change — it is the act of doing your job, and the
-- stated chain (designer designs it, THEN Vijaya proofreads it) cannot happen
-- at all if a designer cannot pass work to Vijaya.
--
-- What is reserved is authority over the work's state: approving, rejecting,
-- requesting changes, holding, cancelling, completing, or sending it backwards.
-- See enforce_status_change_permission() below for exactly where the line falls.
UPDATE public.roles
   SET permissions = (permissions::jsonb || '["submit_work"]'::jsonb)
 WHERE name IN ('CONTENT_WRITER','DESIGNER','SOCIAL_MEDIA','CREATOR')
   AND NOT (permissions ? 'submit_work');

-- ADMIN's own description is "Full system administration" (0001) — it should
-- not need a name-matched STATUS_CONTROLLER grant to actually administer.
-- Named-person grants below stay as the way to hand this to someone who is
-- specifically a controller without also being an ADMIN.
UPDATE public.roles
   SET permissions = (permissions::jsonb || '["change_status"]'::jsonb)
 WHERE name = 'ADMIN'
   AND NOT (permissions ? 'change_status');

CREATE OR REPLACE FUNCTION public.can_change_status()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  -- auth.uid() IS NULL means this is a migration, the seed, or a dashboard
  -- session — not a signed-in app user. Those are already trusted.
  SELECT auth.uid() IS NULL OR public.has_permission('change_status');
$$;

GRANT EXECUTE ON FUNCTION public.can_change_status() TO authenticated;


-- ----------------------------------------------------------------------------
-- Is the current user the person this work item's CURRENT gate routes to?
--
-- Needed because the same instruction that reserves status also describes a
-- chain in which Sushant and Parul verify work. Giving a verdict at a gate you
-- are the registered approver for is doing your job; it is not an override,
-- and blocking it would delete two of the three verification steps the team
-- actually described.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_designated_approver(p_work_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.work_items w
    JOIN public.workflow_stages s ON s.id = w.current_stage_id
    JOIN public.approval_authorities aa
      ON aa.work_category = s.approval_category
     AND aa.is_active
    WHERE w.id = p_work_item_id
      AND s.requires_approval
      AND aa.approver_id = auth.uid()
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_designated_approver(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_status_change_permission()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_old_order INT;
  v_new_order INT;
  v_new_terminal BOOLEAN := FALSE;
  v_is_approver BOOLEAN;
  v_reserved  BOOLEAN := FALSE;
  v_reason    TEXT;
BEGIN
  -- Migrations, the seed and the SQL editor run with no signed-in user.
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF public.can_change_status() THEN RETURN NEW; END IF;

  -- Resolved against the stage the item is LEAVING, which is the gate whose
  -- verdict is being given.
  v_is_approver := public.is_designated_approver(OLD.id);

  SELECT stage_order INTO v_old_order FROM public.workflow_stages WHERE id = OLD.current_stage_id;
  SELECT stage_order, is_terminal INTO v_new_order, v_new_terminal
    FROM public.workflow_stages WHERE id = NEW.current_stage_id;

  -- A verdict on someone's work.
  IF NEW.approval_status IS DISTINCT FROM OLD.approval_status
     AND NEW.approval_status IN ('APPROVED','REJECTED','CHANGES_REQUIRED')
     AND NOT v_is_approver THEN
    v_reserved := TRUE;
    v_reason   := 'approve work or send it back';

  -- Parking or killing work.
  --
  -- COMPLETED is deliberately NOT in this list on its own. Submitting the last
  -- stage moves the item into the terminal stage, and the engine sets
  -- COMPLETED as part of that — so treating every COMPLETED as an override
  -- would block the final handoff for the one person whose job it is (Indu,
  -- posting it). Declaring something complete WITHOUT walking it there is
  -- still reserved.
  ELSIF NEW.status IS DISTINCT FROM OLD.status
        AND (
          NEW.status IN ('ON_HOLD','BLOCKED','CANCELLED','REJECTED')
          OR (NEW.status = 'COMPLETED'
              AND NOT (v_new_terminal AND COALESCE(v_new_order, 0) >= COALESCE(v_old_order, 0)))
        ) THEN
    v_reserved := TRUE;
    v_reason   := 'put work on hold, cancel it or mark it complete';

  -- Pulling something back to an earlier stage.
  ELSIF v_new_order IS NOT NULL AND v_old_order IS NOT NULL AND v_new_order < v_old_order
        AND NOT v_is_approver THEN
    v_reserved := TRUE;
    v_reason   := 'move work back to an earlier stage';

  -- Moving work that is not yours. Passing on your OWN finished work is the
  -- job; moving someone else's is a scheduling decision.
  --
  -- work_item_owners is checked as well as can_edit_work_item(), because on a
  -- COLLABORATIVE item the second collaborator is neither the assignee nor the
  -- owner — they hold half the work and nothing else. Without this, the
  -- multi-owner gate could be opened by one person and never closed by the
  -- other, which is the one case where work would silently stick forever.
  ELSIF NEW.current_stage_id IS DISTINCT FROM OLD.current_stage_id
        AND NOT v_is_approver
        AND NOT public.can_edit_work_item(NEW.id)
        AND NOT EXISTS (
          SELECT 1 FROM public.work_item_owners o
          WHERE o.work_item_id = NEW.id AND o.user_id = auth.uid()
        ) THEN
    v_reserved := TRUE;
    v_reason   := 'move work that is not assigned to you';
  END IF;

  IF v_reserved THEN
    RAISE EXCEPTION
      'Only Vijaya and Nirmal can % . You can submit your own finished work, attach files, add tags and comment.',
      v_reason
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_items_status_permission ON public.work_items;
CREATE TRIGGER trg_work_items_status_permission
  BEFORE UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_status_change_permission();


-- ----------------------------------------------------------------------------
-- Give it to the two people named, by name, the way 0011 assigns every other
-- role. Matching on full_name keeps this working whether or not the import has
-- run, and whether or not they have logins yet.
-- ----------------------------------------------------------------------------
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u
CROSS JOIN public.roles r
WHERE r.name = 'STATUS_CONTROLLER'
  AND lower(btrim(u.full_name)) IN ('vijaya','nirmal')
ON CONFLICT DO NOTHING;

-- The account actually signed in as Vijaya is an ADMIN and may not be named
-- "Vijaya" in full_name, so cover it by email too.
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u
CROSS JOIN public.roles r
WHERE r.name = 'STATUS_CONTROLLER'
  AND lower(u.email) = 'drvijayadutta@gmail.com'
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 4. COMMENTS — replies, resolve, soft delete
-- ============================================================================
-- parent_id and is_resolved have existed since 0004 and were never used by the
-- UI. Nothing to add to the schema; what was missing was a delete policy, so
-- an author could edit a comment but never retract one.
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_comments_parent ON public.comments(parent_id)
  WHERE parent_id IS NOT NULL AND deleted_at IS NULL;

ALTER TABLE public.comments
  ALTER COLUMN author_id SET DEFAULT auth.uid();

-- Soft delete only — the row stays for the audit trail, the body is hidden by
-- the app. Hard DELETE remains closed to everyone but an admin.
DROP POLICY IF EXISTS comments_delete ON public.comments;
CREATE POLICY comments_delete ON public.comments FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN']));


-- ============================================================================
-- 5. Convenience view: work items with their tags, for list filtering
-- ============================================================================
CREATE OR REPLACE VIEW public.v_work_item_tags
WITH (security_invoker = TRUE) AS
SELECT
  wit.work_item_id,
  t.id   AS tag_id,
  t.slug,
  t.label,
  t.colour
FROM public.work_item_tags wit
JOIN public.tags t ON t.id = wit.tag_id;

GRANT SELECT ON public.v_work_item_tags TO authenticated;


-- ####### 0016_parallel_po_track.sql #######

-- ============================================================================
-- 0016_parallel_po_track.sql — procurement runs ALONGSIDE the work, not in
--                              front of it
-- ============================================================================
-- Stated by the team lead:
--   "all PO related tasks should be aligned simultaneously and make it easy
--    to follow"
--
-- WHAT WAS WRONG
--
-- 0008 modelled procurement as a detour on the critical path:
--
--   Department Approval -> PO Request -> Procurement Review -> PO Approval
--                       -> PO Released -> Production -> ...
--
-- So a hoarding whose artwork was signed off on Monday could not START
-- production until a purchase order had been raised, reviewed, approved and
-- issued. Four stages of waiting, during which the work item showed a
-- procurement stage as its status and the creative team had nothing to look at.
-- Every PO item was structurally late.
--
-- WHAT THIS CHANGES
--
-- Procurement becomes a SECOND TRACK that opens the moment departmental
-- approval is given, and runs at the same time as production:
--
--   main track :  Department Approval -> Production -> Final Approval -> Release
--   PO track   :  Requested -> In Review -> Approved -> Released
--                 (opens automatically, at the same moment)
--
-- The real constraint is kept, and only the real one: work cannot go LIVE
-- before the PO is released. Everything up to that point proceeds in parallel.
-- That is enforced at the bottom of this file, with a message that says what
-- is missing rather than silently refusing.
--
-- Idempotent. Safe to run twice.
-- ============================================================================


-- ============================================================================
-- 1. Take procurement off the critical path
-- ============================================================================
-- The fork out of DEPARTMENT_APPROVAL had two edges. Both now lead to
-- PRODUCTION; what po_required decides is no longer WHERE the work goes, but
-- whether a PO track is opened beside it.
--
-- resolve_submit_trigger() still returns 'PO_REQUIRED' / 'NO_PO' and needs no
-- change — the edge it names simply has a different destination now.
-- ----------------------------------------------------------------------------
-- Generic on purpose. Two workflow templates exist (the generic one from 0008
-- and 'Sharda Marketing Workflow' from 0012, which is the default), and the PO
-- fork sits at a DIFFERENT stage in each: DEPARTMENT_APPROVAL in one,
-- FINAL_APPROVAL in the other. Naming either here would have silently fixed
-- one workflow and left the live one untouched.
--
-- So: wherever a PO_REQUIRED edge exists, point it at whatever its NO_PO
-- sibling points at. The fork collapses; po_required stops deciding the route.
UPDATE public.workflow_transitions po
   SET to_stage_id = nopo.to_stage_id,
       description = 'Approved — production starts; PO runs alongside'
  FROM public.workflow_transitions nopo
 WHERE po.trigger_condition   = 'PO_REQUIRED'
   AND nopo.trigger_condition = 'NO_PO'
   AND nopo.from_stage_id     = po.from_stage_id
   AND nopo.workflow_id       = po.workflow_id;


-- ----------------------------------------------------------------------------
-- Mark the four procurement stages as belonging to the parallel track, so the
-- UI can draw them as a side rail instead of numbering them 7-10 of the main
-- line. They stay in the table: work items imported before this migration may
-- still be sitting on one, and deleting the stage would orphan them.
-- ----------------------------------------------------------------------------
ALTER TABLE public.workflow_stages
  ADD COLUMN IF NOT EXISTS track TEXT NOT NULL DEFAULT 'MAIN';

ALTER TABLE public.workflow_stages
  DROP CONSTRAINT IF EXISTS chk_stage_track;
ALTER TABLE public.workflow_stages
  ADD CONSTRAINT chk_stage_track CHECK (track IN ('MAIN','PO'));

UPDATE public.workflow_stages
   SET track = 'PO'
 WHERE name IN ('PO_REQUEST','PROCUREMENT_REVIEW','PO_APPROVAL','PO_RELEASED');

COMMENT ON COLUMN public.workflow_stages.track IS
  'MAIN = the critical path. PO = the procurement track that runs in parallel.
   The stepper renders the two separately.';


-- ============================================================================
-- 2. The PO track itself
-- ============================================================================
-- work_items.po_status already had exactly the right five states
-- (NOT_STARTED -> REQUESTED -> IN_REVIEW -> APPROVED -> RELEASED, plus
-- REJECTED). Nothing new to model: what was missing was anything that MOVED
-- it, and anyone whose job it was to.
-- ----------------------------------------------------------------------------

-- Who approves a PO, and for what value. Resolved from approval_authorities
-- exactly like every other gate — never a constant in code.
CREATE OR REPLACE FUNCTION public.resolve_po_approver(p_amount NUMERIC DEFAULT NULL)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT aa.approver_id
  FROM public.approval_authorities aa
  WHERE aa.is_active
    AND aa.work_category = 'po'
    AND (p_amount IS NULL OR (
          aa.amount_min <= p_amount
          AND (aa.amount_max IS NULL OR aa.amount_max >= p_amount)))
  ORDER BY aa.approval_level, aa.amount_min DESC
  LIMIT 1;
$$;


-- ----------------------------------------------------------------------------
-- Open the PO track for a work item.
--
-- Called automatically by the trigger below when departmental approval is
-- given on PO work, and callable by hand for an item that needs a PO raised
-- earlier or later than usual.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.open_po_track(
  p_work_item_id UUID,
  p_amount       NUMERIC DEFAULT NULL,
  p_description  TEXT    DEFAULT NULL
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_work     public.work_items%ROWTYPE;
  v_po_id    UUID;
  v_approver UUID;
  v_stage    UUID;
BEGIN
  SELECT * INTO v_work FROM public.work_items WHERE id = p_work_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  -- Already open. Returning the existing PO rather than raising keeps the
  -- trigger below idempotent through re-approvals and return paths.
  IF v_work.po_request_id IS NOT NULL THEN
    RETURN v_work.po_request_id;
  END IF;

  v_approver := public.resolve_po_approver(p_amount);

  INSERT INTO public.po_requests (
    work_item_id, amount, description, status, raised_by, submitted_at
  ) VALUES (
    p_work_item_id,
    p_amount,
    COALESCE(p_description, 'Procurement for: ' || v_work.name),
    'SUBMITTED',
    auth.uid(),
    NOW()
  )
  RETURNING id INTO v_po_id;

  UPDATE public.work_items
     SET po_request_id = v_po_id,
         po_status     = 'REQUESTED'
   WHERE id = p_work_item_id;

  -- A task, so the PO shows up in somebody's My Work rather than depending on
  -- a person remembering to look. Without this the parallel track is invisible
  -- and simply becomes a slower version of the old serial one.
  SELECT id INTO v_stage
  FROM public.workflow_stages
  WHERE workflow_id = v_work.workflow_id AND name = 'PO_APPROVAL';

  IF v_approver IS NOT NULL THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, title, instructions,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id,
      v_stage,
      v_approver,
      'Raise and approve PO — ' || v_work.name,
      'Procurement runs alongside production. The work does not wait for this, '
        || 'but it cannot be released until the PO is issued.',
      'APPROVE_PO',
      v_work.priority,
      COALESCE(v_work.deadline, CURRENT_DATE + 3)
    );
  END IF;

  INSERT INTO public.activity_log (work_item_id, actor_id, action, to_value, detail)
  VALUES (p_work_item_id, auth.uid(), 'PO_TRACK_OPENED', 'REQUESTED',
          jsonb_build_object('po_request_id', v_po_id, 'approver_id', v_approver));

  RETURN v_po_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.open_po_track(UUID, NUMERIC, TEXT) TO authenticated;


-- ----------------------------------------------------------------------------
-- Advance the PO track one step, independently of the main workflow.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.advance_po_track(
  p_work_item_id UUID,
  p_to_status    TEXT,
  p_note         TEXT DEFAULT NULL
)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_work public.work_items%ROWTYPE;
  v_next TEXT := upper(btrim(p_to_status));
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.can_change_status() THEN
    RAISE EXCEPTION
      'Only Vijaya and Nirmal can move a purchase order along.'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items WHERE id = p_work_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT v_work.po_required THEN
    RAISE EXCEPTION 'This work item does not need a purchase order'
      USING ERRCODE = '22023';
  END IF;

  IF v_next NOT IN ('REQUESTED','IN_REVIEW','APPROVED','RELEASED','REJECTED') THEN
    RAISE EXCEPTION 'Unknown PO status "%"', v_next USING ERRCODE = '22023';
  END IF;

  UPDATE public.work_items SET po_status = v_next WHERE id = p_work_item_id;

  UPDATE public.po_requests
     SET status = CASE v_next
                    WHEN 'REQUESTED' THEN 'SUBMITTED'
                    WHEN 'IN_REVIEW' THEN 'IN_REVIEW'
                    WHEN 'APPROVED'  THEN 'APPROVED'
                    WHEN 'RELEASED'  THEN 'RELEASED'
                    WHEN 'REJECTED'  THEN 'REJECTED'
                  END,
         approved_by = CASE WHEN v_next IN ('APPROVED','RELEASED')
                            THEN COALESCE(approved_by, auth.uid()) ELSE approved_by END,
         approved_at = CASE WHEN v_next = 'APPROVED' THEN COALESCE(approved_at, NOW())
                            ELSE approved_at END,
         released_at = CASE WHEN v_next = 'RELEASED' THEN COALESCE(released_at, NOW())
                            ELSE released_at END
   WHERE id = v_work.po_request_id;

  -- Close the PO task once procurement is done with it.
  IF v_next IN ('RELEASED','REJECTED') THEN
    UPDATE public.tasks
       SET closed_at = NOW(), status = 'COMPLETED', closed_reason = v_next
     WHERE work_item_id = p_work_item_id
       AND action_type = 'APPROVE_PO'
       AND closed_at IS NULL;
  END IF;

  INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, auth.uid(), 'PO_STATUS_CHANGED',
          v_work.po_status, v_next,
          CASE WHEN p_note IS NULL THEN NULL ELSE jsonb_build_object('note', p_note) END);

  RETURN v_next;
END;
$$;

GRANT EXECUTE ON FUNCTION public.advance_po_track(UUID, TEXT, TEXT) TO authenticated;


-- ============================================================================
-- 3. Open the track automatically, at the same moment approval is given
-- ============================================================================
-- "Simultaneously" has to mean automatically. If opening the PO track were a
-- button someone had to remember to press, procurement would start late again
-- — just for a different reason.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_open_po_track()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_left_po_fork_stage BOOLEAN;
BEGIN
  IF NOT NEW.po_required OR NEW.po_request_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- "The stage the PO fork hangs off", resolved from the transition table
  -- rather than named, for the same reason as above.
  SELECT EXISTS (
    SELECT 1 FROM public.workflow_transitions t
    WHERE t.from_stage_id = OLD.current_stage_id
      AND t.trigger_condition = 'PO_REQUIRED'
  ) INTO v_left_po_fork_stage;

  IF NEW.current_stage_id IS DISTINCT FROM OLD.current_stage_id
     AND v_left_po_fork_stage
  THEN
    PERFORM public.open_po_track(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

-- AFTER, not BEFORE: open_po_track writes to work_items itself, and doing that
-- from a BEFORE trigger on the same row is how you get a recursion that only
-- shows up in production.
DROP TRIGGER IF EXISTS trg_work_items_auto_po ON public.work_items;
CREATE TRIGGER trg_work_items_auto_po
  AFTER UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.auto_open_po_track();


-- ============================================================================
-- 4. The one constraint that survives: nothing goes live without its PO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.enforce_po_before_release()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_entering_release BOOLEAN;
BEGIN
  IF NOT NEW.po_required THEN RETURN NEW; END IF;
  IF NEW.current_stage_id IS NOT DISTINCT FROM OLD.current_stage_id THEN RETURN NEW; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.workflow_stages s
    WHERE s.id = NEW.current_stage_id AND s.name IN ('RELEASE','COMPLETED')
  ) INTO v_entering_release;

  IF v_entering_release AND NEW.po_status NOT IN ('RELEASED','NOT_REQUIRED') THEN
    RAISE EXCEPTION
      'This work cannot be released yet: its purchase order is %, not RELEASED. Production and approvals were free to run in parallel, but release waits for procurement.',
      NEW.po_status
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_items_po_before_release ON public.work_items;
CREATE TRIGGER trg_work_items_po_before_release
  BEFORE UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_po_before_release();


-- ============================================================================
-- 5. Make it easy to follow
-- ============================================================================
-- One row per PO step per work item, already ordered and already labelled
-- done / current / pending. The UI draws it; it does not compute it, so the
-- rail on screen and the rule in the database cannot disagree.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.po_step_rank(p_status TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_status
           WHEN 'NOT_STARTED' THEN 0
           WHEN 'REQUESTED'   THEN 1
           WHEN 'IN_REVIEW'   THEN 2
           WHEN 'APPROVED'    THEN 3
           WHEN 'RELEASED'    THEN 5   -- past the last step: all four are done
           ELSE 0
         END;
$$;

CREATE OR REPLACE VIEW public.v_po_track
WITH (security_invoker = TRUE) AS
WITH steps(step_order, code, label) AS (
  VALUES (1, 'REQUESTED', 'PO raised'),
         (2, 'IN_REVIEW', 'Procurement review'),
         (3, 'APPROVED',  'PO approved'),
         (4, 'RELEASED',  'Issued to vendor')
)
SELECT
  w.id AS work_item_id,
  s.step_order,
  s.code,
  s.label,
  CASE
    WHEN w.po_status = 'REJECTED' THEN 'rejected'
    WHEN s.step_order < public.po_step_rank(w.po_status) THEN 'done'
    WHEN s.step_order = public.po_step_rank(w.po_status) THEN 'current'
    ELSE 'pending'
  END AS state
FROM public.work_items w
CROSS JOIN steps s
WHERE w.po_required;

GRANT EXECUTE ON FUNCTION public.po_step_rank(TEXT) TO authenticated;
GRANT SELECT ON public.v_po_track TO authenticated;


-- ----------------------------------------------------------------------------
-- Backfill: items already sitting on a procurement stage move onto the main
-- track at Production, keeping the PO status they had. Without this they would
-- be stranded on a stage that no longer has an outgoing edge.
-- ----------------------------------------------------------------------------
UPDATE public.work_items w
   SET current_stage_id = prod.id,
       po_status = CASE
                     WHEN w.po_status IN ('NOT_REQUIRED','NOT_STARTED') THEN 'REQUESTED'
                     ELSE w.po_status
                   END
  FROM public.workflow_stages cur,
       public.workflow_stages prod
 WHERE w.current_stage_id = cur.id
   AND cur.track = 'PO'
   AND prod.workflow_id = cur.workflow_id
   AND prod.name = 'PRODUCTION';


-- ####### 0017_creative_chain.sql #######

-- ============================================================================
-- 0017_creative_chain.sql — the creative process as the team actually runs it
-- ============================================================================
-- Stated by the team lead:
--
--   "any creative goes through the process of concept creation, copy creation,
--    designer designs it, then Vijaya proofreads it, then Nirmal/Sushant
--    verifies, then Parul verifies"
--
-- Against what 0012 already had, that is two changes, not a rewrite:
--
--   1. CONCEPT CREATION did not exist. Work went straight from the leadership
--      brief to copywriting, so the step where the idea is actually formed had
--      nowhere to live and no owner.
--
--   2. Vijaya's review was a pass-through stage, not a gate. It could only be
--      "submitted", never "approved" or "sent back" — so a proofread that
--      found problems had no way to return the piece to the designer, and the
--      two verifications above it (Sushant/Nirmal, then Parul) were the only
--      real checkpoints. Proofreading is a verification; it is now modelled as
--      one, matching the two steps that follow it.
--
-- Everything else in the chain was already correct: copy -> design ->
-- Vijaya -> managers -> Parul, each pointing at a ROLE, with the approvers
-- resolved from approval_authorities.
--
-- Idempotent. Safe to run twice.
-- ============================================================================

DO $$
DECLARE
  v_workflow UUID;
BEGIN
  SELECT id INTO v_workflow
  FROM public.workflow_templates
  WHERE name = 'Sharda Marketing Workflow';

  IF v_workflow IS NULL THEN
    RAISE NOTICE 'Sharda Marketing Workflow not present — 0012 has not run. Nothing to do.';
    RETURN;
  END IF;

  -- --------------------------------------------------------------------------
  -- stage_order is UNIQUE per workflow, so inserting a stage in the middle
  -- cannot simply renumber in place — the first UPDATE would collide with a
  -- row that has not moved yet. Park everything above the range first.
  -- --------------------------------------------------------------------------
  UPDATE public.workflow_stages
     SET stage_order = stage_order + 100
   WHERE workflow_id = v_workflow;

  -- --------------------------------------------------------------------------
  -- 1. Concept creation
  -- --------------------------------------------------------------------------
  -- Owned by CONTENT_WRITER. The concept is agreed with the team before copy
  -- is written, and Vijaya is the content lead; no separate "concept" role was
  -- named, and inventing one would create a role nobody holds.
  -- --------------------------------------------------------------------------
  INSERT INTO public.workflow_stages
    (workflow_id, name, stage_order, description,
     requires_approval, requires_attachment, expected_role_id,
     approval_category, is_terminal)
  VALUES (
    v_workflow, 'CONCEPT', 2,
    'The idea and angle agreed before any copy is written',
    FALSE, FALSE,
    (SELECT id FROM public.roles WHERE name = 'CONTENT_WRITER'),
    NULL, FALSE
  )
  ON CONFLICT (workflow_id, name) DO UPDATE
    SET stage_order  = EXCLUDED.stage_order,
        description  = EXCLUDED.description;

  -- --------------------------------------------------------------------------
  -- 2. Final ordering of the main track, then the parallel PO track
  -- --------------------------------------------------------------------------
  UPDATE public.workflow_stages s
     SET stage_order = v.ord,
         description = COALESCE(v.descr, s.description)
    FROM (VALUES
      ('LEADERSHIP_BRIEF',   1,  'Discussion with leadership or the requesting doctor; scope agreed'),
      ('CONCEPT',            2,  'The idea and angle agreed before any copy is written'),
      ('CONTENT',            3,  'Copy and messaging written'),
      ('DESIGN',             4,  'Designer produces the artwork'),
      ('CONTENT_REVIEW',     5,  'Vijaya proofreads the finished piece'),
      ('MANAGER_APPROVAL',   6,  'Nirmal or Sushant verifies'),
      ('FINAL_APPROVAL',     7,  'Parul verifies'),
      ('PRODUCTION',         8,  'Printed, produced or built'),
      ('RELEASE',            9,  'Published, posted or put up'),
      ('COMPLETED',         10,  'Closed out'),
      ('PO_REQUEST',        11,  'Purchase order raised with costing'),
      ('PROCUREMENT_REVIEW',12,  'Vendor and cost checked'),
      ('PO_APPROVAL',       13,  'Purchase order approved'),
      ('PO_RELEASED',       14,  'PO issued to the vendor')
    ) AS v(name, ord, descr)
   WHERE s.workflow_id = v_workflow AND s.name = v.name;

  -- Anything this migration does not know about (a stage added by hand) keeps
  -- its relative position rather than colliding at the bottom.
  UPDATE public.workflow_stages
     SET stage_order = stage_order - 80
   WHERE workflow_id = v_workflow AND stage_order > 100;

  -- --------------------------------------------------------------------------
  -- 3. Vijaya's proofread becomes a real verification gate
  -- --------------------------------------------------------------------------
  UPDATE public.workflow_stages
     SET requires_approval = TRUE,
         approval_category = 'proofread'
   WHERE workflow_id = v_workflow AND name = 'CONTENT_REVIEW';

  -- The PO stages belong to the parallel track introduced in 0016. Re-asserted
  -- here because this migration may run on a database where 0016 has already
  -- set it and the UPDATE above rewrote nothing else about them.
  UPDATE public.workflow_stages
     SET track = 'PO'
   WHERE workflow_id = v_workflow
     AND name IN ('PO_REQUEST','PROCUREMENT_REVIEW','PO_APPROVAL','PO_RELEASED');
END $$;


-- ----------------------------------------------------------------------------
-- 4. Vijaya is the proofread approver
-- ----------------------------------------------------------------------------
-- Matched on name like every other authority in 0011, and on the signed-in
-- account's email as well, because the person who logs in as Vijaya may not
-- be the same row as the "Vijaya" the job list imported.
-- ----------------------------------------------------------------------------
INSERT INTO public.approval_authorities (approver_id, work_category, approval_level)
SELECT u.id, 'proofread', 1
FROM public.users u
WHERE (lower(btrim(u.full_name)) = 'vijaya' OR lower(u.email) = 'drvijayadutta@gmail.com')
  AND NOT EXISTS (
    SELECT 1 FROM public.approval_authorities a
    WHERE a.approver_id = u.id AND a.work_category = 'proofread'
  );

-- An approval gate routes to someone holding APPROVER, so Vijaya needs it for
-- the same reason the managers were given it in 0011.
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE (lower(btrim(u.full_name)) = 'vijaya' OR lower(u.email) = 'drvijayadutta@gmail.com')
  AND r.name = 'APPROVER'
ON CONFLICT (user_id, role_id) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 5. Routing
-- ----------------------------------------------------------------------------
-- CONTENT_REVIEW's outgoing edge changes trigger: it used to leave on
-- SUBMISSION (a pass-through), and now leaves on APPROVED (a gate). The old
-- edge is deleted rather than left in place — a stale SUBMISSION edge out of
-- an approval stage is exactly the kind of leftover that lets work skip a gate.
-- ----------------------------------------------------------------------------
DELETE FROM public.workflow_transitions t
USING public.workflow_stages s, public.workflow_templates w
WHERE t.from_stage_id = s.id
  AND s.workflow_id = w.id
  AND w.name = 'Sharda Marketing Workflow'
  AND s.name = 'CONTENT_REVIEW'
  AND t.trigger_condition = 'SUBMISSION';

WITH w AS (SELECT id FROM public.workflow_templates WHERE name = 'Sharda Marketing Workflow'),
     s AS (SELECT name, id FROM public.workflow_stages WHERE workflow_id = (SELECT id FROM w))
INSERT INTO public.workflow_transitions
  (workflow_id, from_stage_id, to_stage_id, trigger_condition, description)
SELECT (SELECT id FROM w),
       (SELECT id FROM s WHERE s.name = e.from_name),
       (SELECT id FROM s WHERE s.name = e.to_name),
       e.trig, e.descr
FROM (VALUES
  -- The creative chain, in the order it was described
  ('LEADERSHIP_BRIEF',  'CONCEPT',          'SUBMISSION',       'Brief agreed'),
  ('CONCEPT',           'CONTENT',          'SUBMISSION',       'Concept agreed'),
  ('CONTENT',           'DESIGN',           'SUBMISSION',       'Copy ready'),
  ('DESIGN',            'CONTENT_REVIEW',   'SUBMISSION',       'Design ready for proofreading'),
  ('CONTENT_REVIEW',    'MANAGER_APPROVAL', 'APPROVED',         'Vijaya proofread it'),
  ('MANAGER_APPROVAL',  'FINAL_APPROVAL',   'APPROVED',         'Nirmal or Sushant verified'),

  -- Parul's verification releases the work. Both edges lead to production:
  -- since 0016 the purchase order runs alongside rather than in front.
  ('FINAL_APPROVAL',    'PRODUCTION',       'NO_PO',            'Parul verified'),
  ('FINAL_APPROVAL',    'PRODUCTION',       'PO_REQUIRED',      'Parul verified — PO runs alongside'),

  ('PRODUCTION',        'RELEASE',          'SUBMISSION',       'Produced'),
  ('RELEASE',           'COMPLETED',        'SUBMISSION',       'Live'),

  -- Return paths. Each verification sends the piece back to the desk where the
  -- fixing happens, which is the whole point of naming them separately: a
  -- proofreading error goes to the designer, not back to the brief.
  ('CONTENT_REVIEW',    'DESIGN',           'CHANGES_REQUIRED', 'Vijaya wants changes'),
  ('MANAGER_APPROVAL',  'DESIGN',           'CHANGES_REQUIRED', 'Manager wants changes'),
  ('FINAL_APPROVAL',    'DESIGN',           'CHANGES_REQUIRED', 'Parul wants changes'),
  ('PO_APPROVAL',       'PO_REQUEST',       'CHANGES_REQUIRED', 'PO needs reworking')
) AS e(from_name, to_name, trig, descr)
WHERE (SELECT id FROM s WHERE s.name = e.from_name) IS NOT NULL
  AND (SELECT id FROM s WHERE s.name = e.to_name)   IS NOT NULL
ON CONFLICT (workflow_id, from_stage_id, trigger_condition) DO UPDATE
  SET to_stage_id = EXCLUDED.to_stage_id,
      description = EXCLUDED.description;


-- ####### 0018_daily_digest.sql #######

-- ============================================================================
-- 0018_daily_digest.sql — the 6pm end-of-day status digest
-- ============================================================================
-- Stated by the team lead:
--   "everybody should get notification on WhatsApp group at the end of the day
--    6 pm about the status of work aligned for the particular day"
--
-- This file provides the CONTENT. Delivery is in src/app/api/digest/, because
-- of a constraint worth stating plainly rather than discovering later:
--
--   The official WhatsApp Business/Cloud API cannot post to a group. It sends
--   to individual numbers only. Meta has never exposed group messaging, and
--   the services that claim to do it drive an unofficial client that gets
--   numbers banned.
--
-- So the digest is produced once, here, and delivered three ways: an in-app
-- notification per person, an individual WhatsApp message per person where a
-- number and API credentials exist, and a formatted block on /digest that one
-- person pastes into the group in a single tap. The first two are automatic;
-- the third is the honest version of "post it to the group".
--
-- Idempotent. Safe to run twice.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A place to keep the digest secret, so the cron endpoint can read the digest
-- without a service_role key. That key bypasses row-level security entirely
-- and would undo the guarantee the whole schema is built on; a single-purpose
-- shared secret that unlocks exactly one read-only function does not.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_settings (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

-- No policy for `authenticated` at all: RLS with zero policies denies everyone.
-- Only SECURITY DEFINER functions below can read it.
DROP POLICY IF EXISTS app_settings_admin ON public.app_settings;
CREATE POLICY app_settings_admin ON public.app_settings FOR ALL TO authenticated
  USING (public.has_role(ARRAY['ADMIN']))
  WITH CHECK (public.has_role(ARRAY['ADMIN']));

INSERT INTO public.app_settings (key, value)
VALUES ('digest_secret',
        replace(gen_random_uuid()::text, '-', '') ||
        replace(gen_random_uuid()::text, '-', ''))
ON CONFLICT (key) DO NOTHING;


-- ----------------------------------------------------------------------------
-- "Work aligned for the particular day"
--
-- Read as: everything that was supposed to move today. That is wider than
-- "deadline = today" — a digest that omitted the three items that went
-- overdue yesterday would be the most misleading message of the day.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.daily_digest_rows()
RETURNS TABLE (
  bucket        TEXT,
  work_item_id  UUID,
  name          TEXT,
  stage_name    TEXT,
  status        TEXT,
  owner_name    TEXT,
  owner_id      UUID,
  deadline      DATE,
  po_status     TEXT,
  priority      TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    CASE
      WHEN w.status IN ('COMPLETED','CANCELLED')                       THEN 'completed_today'
      WHEN COALESCE(w.stage_deadline, w.deadline) < CURRENT_DATE       THEN 'overdue'
      WHEN COALESCE(w.stage_deadline, w.deadline) = CURRENT_DATE       THEN 'due_today'
      WHEN w.status IN ('ON_HOLD','BLOCKED')                           THEN 'blocked'
      ELSE 'in_flight'
    END AS bucket,
    w.id,
    w.name,
    COALESCE(s.name, 'No stage'),
    w.status,
    u.full_name,
    w.current_assignee_id,
    COALESCE(w.stage_deadline, w.deadline),
    w.po_status,
    w.priority
  FROM public.work_items w
  LEFT JOIN public.workflow_stages s ON s.id = w.current_stage_id
  LEFT JOIN public.users u ON u.id = COALESCE(w.current_assignee_id, w.owner_id)
  WHERE
    -- Everything still open …
    (w.status NOT IN ('COMPLETED','CANCELLED','REJECTED')
     AND (
       COALESCE(w.stage_deadline, w.deadline) <= CURRENT_DATE
       OR w.status IN ('ON_HOLD','BLOCKED')
       OR w.updated_at::date = CURRENT_DATE
     ))
    -- … plus what actually finished today, so the message carries some good news
    OR (w.status IN ('COMPLETED','CANCELLED') AND w.updated_at::date = CURRENT_DATE)
  ORDER BY 1, COALESCE(w.stage_deadline, w.deadline) NULLS LAST, w.name;
$$;


-- ----------------------------------------------------------------------------
-- The whole digest in one call, for the 6pm cron.
--
-- Takes the shared secret rather than a session: this runs from a scheduled
-- job with nobody signed in. It returns status only — names, stages and dates
-- — and no file contents, comments or costs, so the blast radius if the secret
-- leaked is a list of work titles rather than the database.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.daily_digest(p_secret TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_expected TEXT;
  v_result   JSONB;
BEGIN
  SELECT value INTO v_expected FROM public.app_settings WHERE key = 'digest_secret';

  -- md5() is built in; pgcrypto's digest() lives in the extensions schema and
  -- would not resolve under SET search_path = public. Hashing both sides keeps
  -- the comparison length-independent, which is all this needs: the secret
  -- travels over TLS to a cron endpoint, not through a user-facing form.
  IF v_expected IS NULL
     OR md5(COALESCE(p_secret, '')) IS DISTINCT FROM md5(v_expected)
  THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'generated_at', NOW(),
    'date',         CURRENT_DATE,
    'totals', (
      SELECT jsonb_object_agg(bucket, n)
      FROM (SELECT bucket, COUNT(*) AS n FROM public.daily_digest_rows() GROUP BY bucket) x
    ),
    'items', (
      SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.bucket, r.deadline NULLS LAST), '[]'::jsonb)
      FROM public.daily_digest_rows() r
    ),
    'recipients', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'user_id', u.id, 'name', u.full_name, 'phone', u.phone,
               'email', u.email)), '[]'::jsonb)
      FROM public.users u
      WHERE u.is_active
        AND u.email NOT LIKE '%@placeholder.invalid'
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- `anon` is what an unauthenticated cron request arrives as. The secret check
-- inside the function is the actual gate; without it this grant would expose
-- the digest to the internet.
GRANT EXECUTE ON FUNCTION public.daily_digest(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.daily_digest_rows() TO authenticated;


-- ----------------------------------------------------------------------------
-- Record that the digest went out, and give each person an in-app copy.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_digest_sent(p_secret TEXT, p_summary TEXT)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_expected TEXT;
  v_count    INT;
BEGIN
  SELECT value INTO v_expected FROM public.app_settings WHERE key = 'digest_secret';
  IF v_expected IS NULL OR p_secret IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.notifications (recipient_id, type, subject, body, action_url, channel)
  SELECT u.id, 'DAILY_DIGEST',
         'End of day — ' || to_char(CURRENT_DATE, 'DD Mon'),
         p_summary, '/work?filter=active', 'IN_APP'
  FROM public.users u
  WHERE u.is_active AND u.email NOT LIKE '%@placeholder.invalid';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_digest_sent(TEXT, TEXT) TO anon, authenticated;


-- ####### 0019_work_item_journey.sql #######

-- ============================================================================
-- 0019_work_item_journey.sql — the whole journey of a task, with names on it
-- ============================================================================
-- Stated by the team lead:
--   "for each task show the stages in pill format and entire journey should be
--    visible and name written on it that who is taking care of it"
--
-- The stepper already drew pills, but it drew STAGES — "Design", "Content
-- review" — and a stage name does not answer the question anybody actually
-- asks, which is "who has it, and who had it before that". The person was
-- shown once, for the current stage only, in a field lower down the page.
--
-- This view answers it for every stage at once. The tricky part is that
-- "who is taking care of it" means three different things depending on where
-- the stage sits:
--
--   already passed  — who ACTUALLY did it. Not who was supposed to: work gets
--                     reassigned, and the history should say what happened.
--   current         — who holds it right now.
--   still to come   — who it WILL route to, resolved the same way the engine
--                     will resolve it when it gets there (approval_authorities
--                     for a gate), so the pill and the future agree.
--
-- Where no person can be named — a future stage that routes by role rather
-- than to a registered approver — the view returns the ROLE and leaves the
-- name NULL, so the UI can say "a designer" rather than inventing a person.
--
-- Idempotent. Safe to run twice.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_work_item_journey
WITH (security_invoker = TRUE) AS
SELECT
  w.id                       AS work_item_id,
  s.id                       AS stage_id,
  s.name                     AS stage_name,
  s.stage_order,
  s.track,
  s.requires_approval,
  s.is_terminal,

  -- Where this stage sits relative to the work item's position.
  CASE
    WHEN cur.stage_order IS NULL              THEN 'upcoming'
    WHEN s.stage_order  <  cur.stage_order    THEN 'done'
    WHEN s.stage_order  =  cur.stage_order    THEN 'current'
    ELSE 'upcoming'
  END                        AS state,

  -- Who is taking care of it.
  COALESCE(
    -- Passed: whoever actually submitted or approved at this stage. Approvals
    -- first, because on a gate the approver's verdict is the event that
    -- mattered; the submission into the gate belongs to the stage before.
    approver.full_name,
    submitter.full_name,
    -- Current: the person holding it now.
    CASE WHEN s.stage_order = cur.stage_order
         THEN COALESCE(assignee.full_name, owner.full_name, w.pending_with_label)
    END,
    -- Upcoming gate: whoever the engine will route to when it arrives.
    gate_approver.full_name
  )                          AS person_name,

  COALESCE(approver.id, submitter.id,
           CASE WHEN s.stage_order = cur.stage_order
                THEN COALESCE(assignee.id, owner.id) END,
           gate_approver.id) AS person_id,

  -- The fallback when nobody can be named: what KIND of person holds it.
  r.name                     AS role_name,

  -- When it happened, for the tooltip on a completed pill.
  COALESCE(appr.decided_at, sub.submitted_at) AS acted_at

FROM public.work_items w
JOIN public.workflow_stages s
  ON s.workflow_id = w.workflow_id
LEFT JOIN public.workflow_stages cur
  ON cur.id = w.current_stage_id
LEFT JOIN public.roles r
  ON r.id = s.expected_role_id

-- The most recent approval given at this stage, for this item.
LEFT JOIN LATERAL (
  SELECT a.approver_id, a.decided_at
  FROM public.approvals a
  WHERE a.work_item_id = w.id AND a.stage_id = s.id
  ORDER BY a.decided_at DESC
  LIMIT 1
) appr ON TRUE
LEFT JOIN public.users approver ON approver.id = appr.approver_id

-- The most recent submission made from this stage, for this item.
LEFT JOIN LATERAL (
  SELECT sm.submitted_by, sm.submitted_at
  FROM public.submissions sm
  WHERE sm.work_item_id = w.id AND sm.stage_id = s.id
  ORDER BY sm.submitted_at DESC
  LIMIT 1
) sub ON TRUE
LEFT JOIN public.users submitter ON submitter.id = sub.submitted_by

LEFT JOIN public.users assignee ON assignee.id = w.current_assignee_id
LEFT JOIN public.users owner    ON owner.id    = w.owner_id

-- Who a future approval gate will route to. Lowest active level wins, which is
-- the same rule resolve_approver() uses, so the pill does not promise one
-- person and the engine then pick another.
LEFT JOIN LATERAL (
  SELECT u.id, u.full_name
  FROM public.approval_authorities aa
  JOIN public.users u ON u.id = aa.approver_id
  WHERE aa.is_active
    AND s.requires_approval
    AND aa.work_category = s.approval_category
  ORDER BY aa.approval_level, aa.created_at
  LIMIT 1
) gate_approver ON TRUE

-- Procurement stages belong to the parallel rail (0016) and are drawn
-- separately; on work that needs no PO they are not part of the journey at all.
WHERE s.track = 'MAIN' OR w.po_required;

GRANT SELECT ON public.v_work_item_journey TO authenticated;

COMMENT ON VIEW public.v_work_item_journey IS
  'One row per stage per work item: where it sits, and who is taking care of
   it — the person who actually did it for passed stages, the current holder
   for the current one, and the person the engine will route to for stages
   still to come.';


-- ####### 0020_restrict_job_creation.sql #######

-- ============================================================================
-- 0020_restrict_job_creation.sql — only an ADMIN may start new work
-- ============================================================================
-- Creating work was open to ADMIN, WORKFLOW_MANAGER and COORDINATOR (0006).
-- It is now ADMIN only. Everyone else keeps everything else: a workflow
-- manager still sees the Control Tower, still reassigns, still approves — they
-- simply cannot open a new job.
--
-- Two policies have to move, not one.
--
-- work_items_insert was the obvious half: a straight role list.
--
-- jobs_write was the half that would have been missed. It is FOR ALL with
--
--   WITH CHECK (has_role(...) OR created_by = auth.uid() OR requester_id = auth.uid())
--
-- and on an INSERT only WITH CHECK is evaluated — so that second branch let
-- ANY authenticated user insert a job simply by putting their own id in
-- created_by. Narrowing the role list alone would have left that path wide
-- open and made this migration a lie. The INSERT case is therefore split out
-- of the FOR ALL policy and given its own ADMIN-only rule; UPDATE and DELETE
-- keep the original behaviour, so a requester can still edit the job they are
-- attached to.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- work_items: only an ADMIN may create one
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS work_items_insert ON public.work_items;
CREATE POLICY work_items_insert ON public.work_items FOR INSERT TO authenticated
  WITH CHECK (public.has_role(ARRAY['ADMIN']));

-- ----------------------------------------------------------------------------
-- jobs: INSERT split away from UPDATE/DELETE
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS jobs_write ON public.jobs;

DROP POLICY IF EXISTS jobs_insert ON public.jobs;
CREATE POLICY jobs_insert ON public.jobs FOR INSERT TO authenticated
  WITH CHECK (public.has_role(ARRAY['ADMIN']));

-- Unchanged from the old jobs_write, minus the INSERT case: whoever the job
-- belongs to can still maintain it.
DROP POLICY IF EXISTS jobs_modify ON public.jobs;
CREATE POLICY jobs_modify ON public.jobs FOR UPDATE TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid())
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid());

DROP POLICY IF EXISTS jobs_delete ON public.jobs;
CREATE POLICY jobs_delete ON public.jobs FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid());


-- ####### 0021_submit_status_controller_override.sql #######

-- ============================================================================
-- 0021_submit_status_controller_override.sql
--   Let a STATUS_CONTROLLER (Vijaya, Nirmal) or ADMIN submit_for_next_stage
--   on work they do not personally hold.
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- 0015 introduced public.can_change_status() and wired it into
-- enforce_status_change_permission() so that approve_work_item and
-- request_changes already let a controller act on work that is neither
-- theirs nor at their gate ("move work that is neither theirs nor at their
-- gate" is explicitly one of the things 0015 reserves to Vijaya/Nirmal).
--
-- submit_for_next_stage was never given the same exception: it has always had
-- its own, separate ownership guard ("You do not hold this work item",
-- ERRCODE 42501) that runs before the trigger ever sees the UPDATE, and that
-- guard has no can_change_status() branch. So even a controller calling
-- submit_for_next_stage on a card they don't hold was — and, absent this
-- migration, still is — rejected by that guard alone, regardless of role.
--
-- This is the server-side half of the Board fix (see
-- src/lib/workflow/board.ts's canOverride): the Board now offers the drag to
-- a controller for cards they don't hold, but that drag calls this exact
-- function for the "forward, no approval gate" case, so without this change
-- the drag would succeed in the UI and then fail with "You do not hold this
-- work item" on drop.
--
-- Only the guard clause changes; everything else is byte-for-byte the
-- function from 0007. p_task then legitimately stays NULL for an override
-- call — already handled throughout (see "IF v_task.id IS NOT NULL" below),
-- since PARALLEL/SEQUENTIAL work and the closing of "this person's task" were
-- always optional depending on whether the actor held a task.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.submit_for_next_stage(
  p_work_item_id UUID,
  p_notes        TEXT DEFAULT NULL,
  p_file_ids     UUID[] DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor          UUID := auth.uid();
  v_work           public.work_items%ROWTYPE;
  v_stage          public.workflow_stages%ROWTYPE;
  v_multi_mode     TEXT;
  v_task           public.tasks%ROWTYPE;
  v_trigger        TEXT;
  v_next_stage_id  UUID;
  v_next_stage     public.workflow_stages%ROWTYPE;
  v_transition_found BOOLEAN;
  v_next_assignee  UUID;
  v_next_deadline  DATE;
  v_submission_id  UUID;
  v_submission_no  INT;
  v_new_task_id    UUID;
  v_pending_total  INT;
  v_missing_files  INT;
  v_next_status    TEXT;
  v_action_type    TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  -- Lock the row for the duration of the transaction so two people clicking
  -- Submit at the same moment cannot both advance the stage.
  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot be submitted', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before submitting.'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  SELECT multi_owner_behavior INTO v_multi_mode
  FROM public.workflow_templates WHERE id = v_work.workflow_id;

  -- ---- 1. VALIDATE -------------------------------------------------------
  -- The caller must actually hold this work: an open task, or be the
  -- assignee/owner. A STATUS_CONTROLLER / ADMIN (public.can_change_status())
  -- is exempt, mirroring the exemption enforce_status_change_permission()
  -- already gives approve_work_item and request_changes (0015) — moving work
  -- that is neither theirs nor at their gate is exactly what that role is for.
  SELECT * INTO v_task FROM public.tasks
  WHERE work_item_id = p_work_item_id
    AND assignee_id = v_actor
    AND closed_at IS NULL
  LIMIT 1;

  IF NOT FOUND
     AND v_work.current_assignee_id IS DISTINCT FROM v_actor
     AND v_work.owner_id IS DISTINCT FROM v_actor
     AND NOT EXISTS (
       SELECT 1 FROM public.work_item_owners
       WHERE work_item_id = p_work_item_id AND user_id = v_actor
     )
     AND NOT public.can_change_status()
  THEN
    RAISE EXCEPTION 'You do not hold this work item' USING ERRCODE = '42501';
  END IF;

  IF v_stage.requires_attachment THEN
    SELECT COUNT(*) INTO v_missing_files
    FROM public.files
    WHERE work_item_id = p_work_item_id
      AND deleted_at IS NULL
      AND (stage_id = v_stage.id OR stage_id IS NULL);

    IF v_missing_files = 0 THEN
      RAISE EXCEPTION 'Stage "%" requires at least one attachment', v_stage.name
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- ---- 2. RECORD THE SUBMISSION (append-only) ----------------------------
  v_submission_no := COALESCE(v_work.submission_count, 0) + 1;

  INSERT INTO public.submissions (
    work_item_id, task_id, stage_id, submission_number, submitted_by, notes, snapshot
  ) VALUES (
    p_work_item_id, v_task.id, v_stage.id, v_submission_no, v_actor, p_notes,
    jsonb_build_object(
      'status', v_work.status,
      'stage_id', v_work.current_stage_id,
      'stage_name', v_stage.name,
      'assignee_id', v_work.current_assignee_id,
      'priority', v_work.priority,
      'stage_deadline', v_work.stage_deadline
    )
  ) RETURNING id INTO v_submission_id;

  IF p_file_ids IS NOT NULL THEN
    UPDATE public.files
    SET submission_id = v_submission_id
    WHERE id = ANY(p_file_ids) AND work_item_id = p_work_item_id;
  END IF;

  -- Close this person's task
  IF v_task.id IS NOT NULL THEN
    UPDATE public.tasks
    SET status = 'SUBMITTED', closed_at = NOW(), closed_reason = 'Submitted for next stage'
    WHERE id = v_task.id;
  END IF;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, detail)
  VALUES (p_work_item_id, v_task.id, v_actor, 'SUBMITTED',
          jsonb_build_object('stage', v_stage.name, 'submission_number', v_submission_no,
                             'notes', p_notes));

  -- ---- 3. MULTI-OWNER GATE ----------------------------------------------
  -- PARALLEL work only advances once every collaborator has submitted.
  IF v_multi_mode = 'PARALLEL' THEN
    UPDATE public.work_item_owners
    SET submission_status = 'SUBMITTED', submitted_at = NOW()
    WHERE work_item_id = p_work_item_id AND user_id = v_actor;

    SELECT COUNT(*) INTO v_pending_total
    FROM public.work_item_owners
    WHERE work_item_id = p_work_item_id AND submission_status = 'PENDING';

    IF v_pending_total > 0 THEN
      UPDATE public.work_items
      SET status = 'SUBMITTED',
          substatus = format('Waiting on %s more collaborator(s)', v_pending_total),
          submission_count = v_submission_no
      WHERE id = p_work_item_id;

      -- Nudge whoever is still holding it
      INSERT INTO public.notifications (recipient_id, work_item_id, type, subject, body, action_url)
      SELECT o.user_id, p_work_item_id, 'ASSIGNMENT',
             format('Still awaiting your submission: %s', v_work.name),
             format('%s has submitted. This work advances once all collaborators submit.',
                    (SELECT full_name FROM public.users WHERE id = v_actor)),
             '/work/' || p_work_item_id
      FROM public.work_item_owners o
      WHERE o.work_item_id = p_work_item_id AND o.submission_status = 'PENDING';

      RETURN jsonb_build_object(
        'advanced', FALSE,
        'reason', 'awaiting_collaborators',
        'pending_collaborators', v_pending_total,
        'submission_id', v_submission_id
      );
    END IF;
  END IF;

  -- SEQUENTIAL hands to the next collaborator in order before leaving the stage.
  IF v_multi_mode = 'SEQUENTIAL' THEN
    UPDATE public.work_item_owners
    SET submission_status = 'SUBMITTED', submitted_at = NOW()
    WHERE work_item_id = p_work_item_id AND user_id = v_actor;

    SELECT o.user_id INTO v_next_assignee
    FROM public.work_item_owners o
    WHERE o.work_item_id = p_work_item_id
      AND o.submission_status = 'PENDING'
    ORDER BY o.sequence_order NULLS LAST, o.assigned_at
    LIMIT 1;

    IF v_next_assignee IS NOT NULL THEN
      v_next_deadline := public.compute_stage_deadline(v_stage.id, v_work.priority);

      INSERT INTO public.tasks (
        work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
        action_type, priority, due_date
      ) VALUES (
        p_work_item_id, v_stage.id, v_next_assignee, v_actor,
        format('%s — %s', v_work.name, v_stage.name),
        p_notes, 'COMPLETE_STAGE', v_work.priority, v_next_deadline
      ) RETURNING id INTO v_new_task_id;

      UPDATE public.work_items
      SET current_assignee_id = v_next_assignee,
          pending_with_id     = v_next_assignee,
          pending_with_label  = NULL,
          status              = 'IN_PROGRESS',
          stage_deadline      = v_next_deadline,
          submission_count    = v_submission_no,
          handoff_at          = NOW(),
          handoff_by          = v_actor
      WHERE id = p_work_item_id;

      INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value)
      VALUES (p_work_item_id, v_new_task_id, v_actor, 'ASSIGNED',
              (SELECT full_name FROM public.users WHERE id = v_actor),
              (SELECT full_name FROM public.users WHERE id = v_next_assignee));

      INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
      VALUES (v_next_assignee, p_work_item_id, v_new_task_id, 'ASSIGNMENT',
              format('Your turn: %s', v_work.name),
              format('Handed to you at stage %s.', v_stage.name),
              '/work/' || p_work_item_id);

      RETURN jsonb_build_object(
        'advanced', FALSE,
        'reason', 'sequential_handoff',
        'next_assignee_id', v_next_assignee,
        'task_id', v_new_task_id
      );
    END IF;
  END IF;

  -- ---- 4. MOVE STAGE -----------------------------------------------------
  v_trigger := public.resolve_submit_trigger(v_stage.id, v_work.po_required);

  SELECT t.to_stage_id, TRUE INTO v_next_stage_id, v_transition_found
  FROM public.workflow_transitions t
  WHERE t.from_stage_id = v_stage.id
    AND t.trigger_condition = v_trigger
    AND t.is_active
  LIMIT 1;

  IF NOT COALESCE(v_transition_found, FALSE) THEN
    RAISE EXCEPTION 'No % transition configured out of stage "%"', v_trigger, v_stage.name
      USING ERRCODE = '22023',
            HINT = 'Add a workflow_transitions row for this stage.';
  END IF;

  -- End of workflow
  IF v_next_stage_id IS NULL THEN
    UPDATE public.work_items
    SET status = 'COMPLETED',
        previous_stage_id = v_stage.id,
        current_stage_id  = NULL,
        current_assignee_id = NULL,
        pending_with_id   = NULL,
        pending_with_label= NULL,
        stage_deadline    = NULL,
        submission_count  = v_submission_no,
        completed_at      = NOW(),
        handoff_at        = NOW(),
        handoff_by        = v_actor
    WHERE id = p_work_item_id;

    INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value)
    VALUES (p_work_item_id, v_actor, 'COMPLETED', v_stage.name, NULL);

    RETURN jsonb_build_object('advanced', TRUE, 'completed', TRUE,
                              'submission_id', v_submission_id);
  END IF;

  SELECT * INTO v_next_stage FROM public.workflow_stages WHERE id = v_next_stage_id;

  -- ---- 5. IDENTIFY NEXT ASSIGNEE ----------------------------------------
  v_next_assignee := public.resolve_next_assignee(p_work_item_id, v_next_stage_id);
  v_next_deadline := public.compute_stage_deadline(v_next_stage_id, v_work.priority);

  v_action_type := CASE
    WHEN v_next_stage.requires_approval THEN 'APPROVE'
    ELSE 'COMPLETE_STAGE'
  END;

  -- A workflow can end two ways: a transition pointing at nothing (handled
  -- above), or landing on a stage flagged is_terminal. The 11-stage flow uses
  -- the second form because "Completed" is a real stage users need to see in
  -- the progress tracker -- without this it would sit there as IN_PROGRESS.
  v_next_status := CASE
    WHEN v_next_stage.is_terminal       THEN 'COMPLETED'
    WHEN v_next_stage.requires_approval THEN 'PENDING'
    WHEN v_next_assignee IS NULL        THEN 'PENDING'
    ELSE 'IN_PROGRESS'
  END;

  -- ---- 6. CREATE NEXT TASK ----------------------------------------------
  -- No task on a terminal stage: there is nothing left for anyone to do.
  IF v_next_assignee IS NOT NULL AND NOT v_next_stage.is_terminal THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id, v_next_stage_id, v_next_assignee, v_actor,
      format('%s — %s', v_work.name, v_next_stage.name),
      p_notes, v_action_type, v_work.priority, v_next_deadline
    ) RETURNING id INTO v_new_task_id;
  END IF;

  -- Reset collaborator submission flags for the new stage
  UPDATE public.work_item_owners
  SET submission_status = 'PENDING', submitted_at = NULL
  WHERE work_item_id = p_work_item_id;

  UPDATE public.work_items
  SET previous_stage_id  = v_stage.id,
      current_stage_id   = v_next_stage_id,
      -- Finished work is pending with nobody. Leaving an assignee on a
      -- terminal stage would keep it sitting in that person's My Work queue
      -- forever.
      current_assignee_id= CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_assignee END,
      pending_with_id    = CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_assignee END,
      pending_with_label = CASE
                             WHEN v_next_stage.is_terminal THEN NULL
                             WHEN v_next_assignee IS NULL   THEN 'unassigned'
                             ELSE NULL END,
      status             = v_next_status,
      substatus          = NULL,
      approval_required  = v_next_stage.requires_approval,
      approval_status    = CASE WHEN v_next_stage.requires_approval
                                THEN 'PENDING' ELSE approval_status END,
      stage_deadline     = CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_deadline END,
      submission_count   = v_submission_no,
      completed_at       = CASE WHEN v_next_stage.is_terminal THEN NOW() ELSE completed_at END,
      handoff_at         = NOW(),
      handoff_by         = v_actor
  WHERE id = p_work_item_id;

  -- ---- 7. ACTIVITY LOG ---------------------------------------------------
  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_new_task_id, v_actor, 'STAGE_CHANGED',
          v_stage.name, v_next_stage.name,
          jsonb_build_object('trigger', v_trigger, 'submission_id', v_submission_id));

  IF v_next_assignee IS NOT NULL THEN
    INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, to_value)
    VALUES (p_work_item_id, v_new_task_id, v_actor, 'ASSIGNED',
            (SELECT full_name FROM public.users WHERE id = v_next_assignee));
  ELSE
    INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
    VALUES (p_work_item_id, v_actor, 'UNASSIGNED',
            jsonb_build_object('reason', 'no approval authority or owner configured',
                               'stage', v_next_stage.name));
  END IF;

  -- ---- 8. NOTIFY ---------------------------------------------------------
  IF v_next_assignee IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
    VALUES (
      v_next_assignee, p_work_item_id, v_new_task_id,
      CASE WHEN v_next_stage.requires_approval THEN 'APPROVAL_REQUIRED' ELSE 'ASSIGNMENT' END,
      format('%s: %s', CASE WHEN v_next_stage.requires_approval
                            THEN 'Approval needed' ELSE 'New work assigned' END, v_work.name),
      format('Stage: %s. %s',
             v_next_stage.name,
             COALESCE('Due ' || v_next_deadline::TEXT, 'No due date set')),
      '/work/' || p_work_item_id
    );
  END IF;

  RETURN jsonb_build_object(
    'advanced', TRUE,
    'completed', FALSE,
    'from_stage', v_stage.name,
    'to_stage', v_next_stage.name,
    'trigger', v_trigger,
    'next_assignee_id', v_next_assignee,
    'task_id', v_new_task_id,
    'stage_deadline', v_next_deadline,
    'submission_id', v_submission_id
  );
END;
$$;


-- ####### 0022_status_controller_edit_override.sql #######

-- ============================================================================
-- 0022_status_controller_edit_override.sql
--   Wire the STATUS_CONTROLLER / ADMIN change_status override into the RLS
--   layer that actually gates row access, not just the plpgsql trigger.
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- 0015 added public.can_change_status() and an early-return for it inside
-- enforce_status_change_permission() (the BEFORE UPDATE trigger on
-- work_items), so a controller's UPDATE is never blocked by the "reserved
-- action" checks that stop everyone else. That made it LOOK like a
-- STATUS_CONTROLLER could act on any work_item -- but a Postgres RLS UPDATE
-- policy's USING clause is checked before a trigger ever runs, and
-- `SELECT ... FOR UPDATE` is checked against the UPDATE policy too, not just
-- SELECT. public.can_edit_work_item() -- the USING/WITH CHECK clause on
-- work_items_update (0006) -- was never given the same exception, so:
--
--   * approve_work_item() and request_changes() (0007), and
--     submit_for_next_stage() after 0021,
--   * and any direct work_items UPDATE from the client,
--
-- all still open with `SELECT ... FOR UPDATE` (or run their final UPDATE)
-- against a row a plain STATUS_CONTROLLER cannot see through can_edit_work_item
-- -- so it silently returns zero rows / "Work item not found" before the
-- trigger's can_change_status() bypass is ever reached. This has been true
-- since 0015 shipped; it was never exercised by a real, non-admin controller
-- in the test suite, so it went unnoticed. Confirmed directly: a user who is
-- ONLY STATUS_CONTROLLER (not ADMIN or WORKFLOW_MANAGER, not the item's
-- owner/assignee/task-holder) gets "Work item not found" from
-- approve_work_item() today, even though enforce_status_change_permission()
-- would have let the change through.
--
-- Fix: can_edit_work_item() gains the same public.can_change_status()
-- exception the trigger already grants. This does not widen what a
-- controller may change (enforce_status_change_permission() already permits
-- a change_status holder to update any field, unconditionally -- see its own
-- `IF public.can_change_status() THEN RETURN NEW; END IF;`), it only lets
-- that already-granted permission actually reach the row.
--
-- `SELECT ... FOR UPDATE` under RLS is gated by the SELECT policy's USING
-- clause AND the applicable command's (UPDATE) USING clause together -- both
-- must pass, not just one -- so can_see_work_item() (0004, the SELECT policy)
-- needs the identical exception, or a controller's row is filtered out
-- before can_edit_work_item() is even consulted. Confirmed by testing both
-- functions independently against the same row for a plain controller: fixing
-- only can_edit_work_item() left `SELECT ... FOR UPDATE` still returning zero
-- rows until can_see_work_item() got the same exception.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.can_see_work_item(p_work_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR public.can_change_status()
    OR EXISTS (
      SELECT 1 FROM public.work_items w
      WHERE w.id = p_work_item_id
        AND (
          w.owner_id = auth.uid()
          OR w.current_assignee_id = auth.uid()
          OR w.pending_with_id = auth.uid()
          OR w.requester_id = auth.uid()
          OR w.created_by = auth.uid()
        )
    )
    OR EXISTS (
      SELECT 1 FROM public.work_item_owners o
      WHERE o.work_item_id = p_work_item_id AND o.user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM public.tasks t
      WHERE t.work_item_id = p_work_item_id AND t.assignee_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION public.can_edit_work_item(p_work_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER'])
    OR public.can_change_status()
    OR EXISTS (
      SELECT 1 FROM public.work_items w
      WHERE w.id = p_work_item_id
        AND (w.owner_id = auth.uid() OR w.current_assignee_id = auth.uid())
    )
    OR EXISTS (
      SELECT 1 FROM public.tasks t
      WHERE t.work_item_id = p_work_item_id
        AND t.assignee_id = auth.uid()
        AND t.closed_at IS NULL
    );
$$;


-- ####### 0023_po_and_audit_rls_fixes.sql #######

-- ============================================================================
-- 0023_po_and_audit_rls_fixes.sql
--   Close a po_requests self-attribution INSERT bypass (the same class 0020
--   fixed on jobs), wire the change_status override into po_requests the
--   way 0022 wired it into work_items, and stop activity_log accepting an
--   arbitrary actor_id.
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- 1. po_requests_write (0006) is FOR ALL with
--    WITH CHECK (raised_by = auth.uid() OR has_role(ADMIN/WORKFLOW_MANAGER/
--    COORDINATOR)). On INSERT only WITH CHECK runs, so any authenticated
--    user can raise a PO against ANY work_item_id -- including one they
--    cannot see, or NULL -- purely by naming themselves as raised_by. This
--    is the identical shape of hole 0020 closed on jobs_write; po_requests
--    was simply never given the same split. The app's own UI never takes
--    this path (PO creation goes through the open_po_track RPC), but RLS,
--    not the UI, is this project's security boundary throughout.
--
-- 2. advance_po_track() (0016) is SECURITY DEFINER owned by a role that
--    bypasses RLS, so it was never actually blocked by po_requests_write --
--    its own can_change_status() check is sufficient there. But
--    updatePoDetails() (collab.ts) does a plain client-side .update() on
--    po_requests, which DOES run under RLS as the authenticated role. That
--    policy has no can_change_status() exception, unlike can_see_work_item/
--    can_edit_work_item after 0022 -- confirmed live: a STATUS_CONTROLLER
--    who did not personally raise a PO gets `UPDATE 0`, no error, while the
--    UI reports success. Vijaya (STATUS_CONTROLLER only, no COORDINATOR/
--    ADMIN/WORKFLOW_MANAGER) hits this today.
--
-- 3. activity_log_insert (0006) only checks can_see_work_item(work_item_id)
--    -- nothing ties the inserted actor_id to the caller, so a crafted
--    request could attribute any row for a visible work item to any other
--    user. NULL stays allowed (several call sites, e.g. collab.ts's
--    file-attach/remove entries, do not set an actor at all today).
-- ============================================================================

DROP POLICY IF EXISTS po_requests_write ON public.po_requests;

DROP POLICY IF EXISTS po_requests_insert ON public.po_requests;
CREATE POLICY po_requests_insert ON public.po_requests FOR INSERT TO authenticated
  WITH CHECK (
    public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR (
      raised_by = auth.uid()
      AND work_item_id IS NOT NULL
      AND public.can_see_work_item(work_item_id)
    )
  );

DROP POLICY IF EXISTS po_requests_modify ON public.po_requests;
CREATE POLICY po_requests_modify ON public.po_requests FOR UPDATE TO authenticated
  USING (
    raised_by = auth.uid()
    OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR public.can_change_status()
  )
  WITH CHECK (
    raised_by = auth.uid()
    OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR public.can_change_status()
  );

DROP POLICY IF EXISTS po_requests_delete ON public.po_requests;
CREATE POLICY po_requests_delete ON public.po_requests FOR DELETE TO authenticated
  USING (
    raised_by = auth.uid()
    OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
    OR public.can_change_status()
  );

DROP POLICY IF EXISTS activity_log_insert ON public.activity_log;
CREATE POLICY activity_log_insert ON public.activity_log FOR INSERT TO authenticated
  WITH CHECK (
    public.can_see_work_item(work_item_id)
    AND (actor_id IS NULL OR actor_id = auth.uid())
  );


-- ####### 0024_anshika_video_editor.sql #######

-- ============================================================================
-- 0024_anshika_video_editor.sql — Anshika, properly set up
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Anshika already exists in the seeded data (database/supabase-bundle/02_seed.sql
-- inserted her as anshika@placeholder.invalid / 'Anshika' -- she's the
-- owner/collaborator on "ShardaCare hai na film", fittingly a video job --
-- because the imported job list named her but gave no contact details. Like
-- all 17 imported people she only holds the blanket bootstrap CREATOR role;
-- per database/SETUP.md that exists only "so RLS can be tested; reassign
-- properly before real use."
--
-- This gives her the real discipline (video editor) and her real official
-- email in place of the placeholder.
--
-- NOTE: a real email takes her out of 0018_daily_digest.sql's
-- `WHERE u.email NOT LIKE '%@placeholder.invalid'` filter on both the daily
-- digest recipient list and in-app notifications -- she starts receiving
-- those. That's the point of giving her a real address, not a side effect
-- to work around.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Role for the discipline. Mirrors DESIGNER's permission set exactly (which
-- is also CREATOR's -- this is a discipline label for routing/display, not a
-- change in what she's allowed to do).
-- ----------------------------------------------------------------------------
INSERT INTO public.roles (name, description, permissions) VALUES
  ('VIDEO_EDITOR', 'Edits and produces video content',
   '["view_own","submit_work","upload_files","add_comments"]')
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      permissions = EXCLUDED.permissions;

-- ----------------------------------------------------------------------------
-- Her person row. Two cases:
--   1. A row already has the real email (this migration ran before, or ran
--      after the placeholder was already renamed) -> no-op.
--   2. The placeholder row from the import exists -> UPDATE it in place, so
--      her user id -- and the FK references from her two existing imported
--      work items -- stay intact.
--
-- Deliberately does NOT insert her fresh when neither row exists yet (e.g. a
-- from-scratch bootstrap where migrations run before 02_seed.sql, per
-- database/SETUP.md's own documented order). Tested that path directly:
-- inserting a fresh row here, then letting 02_seed.sql run afterward and
-- insert ITS OWN anshika@placeholder.invalid row (a different email, so
-- ON CONFLICT (email) does not catch it), produces two people -- and the
-- imported work item's owner_id ends up on the wrong one, since the import
-- links by the placeholder email, not the real one. Skipping cleanly here
-- instead means: on that path, re-running this same bundle a second time
-- (the standard fix this project already tells you to do all over
-- 00_diagnose.sql -- "re-paste and re-run 01_schema.sql") finds the
-- placeholder row seed created and updates it correctly, with no duplicate
-- ever created.
-- ----------------------------------------------------------------------------
UPDATE public.users
   SET email = 'anshika.pundhir@shardacare.com',
       full_name = 'Anshika Pundhir'
 WHERE email = 'anshika@placeholder.invalid';

-- ----------------------------------------------------------------------------
-- Grant the real role, drop the bootstrap one -- matching what every one of
-- 0011's nine real team members ended up with (one discipline role, not
-- CREATOR-plus-discipline). No access is lost: identical permission set.
-- ----------------------------------------------------------------------------
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE u.email = 'anshika.pundhir@shardacare.com' AND r.name = 'VIDEO_EDITOR'
ON CONFLICT (user_id, role_id) DO NOTHING;

DELETE FROM public.user_roles ur
USING public.users u, public.roles r
WHERE ur.user_id = u.id AND ur.role_id = r.id
  AND u.email = 'anshika.pundhir@shardacare.com' AND r.name = 'CREATOR';


-- ####### 0025_work_visible_to_all.sql #######

-- ============================================================================
-- 0025_work_visible_to_all.sql — every signed-in user can see all work
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Product decision: overall work should be visible to everyone on the team,
-- not just ADMIN/WORKFLOW_MANAGER/COORDINATOR (or whoever happens to own,
-- be assigned, or hold a task on a given item). This is a READ change only
-- -- who may EDIT a work item (public.can_edit_work_item, still ownership/
-- role-based) is untouched, as is who may create work (0020, ADMIN only),
-- delete it, move it between stages (0015/0021/0022, STATUS_CONTROLLER/
-- ADMIN), or approve it. Seeing everything is not the same as being allowed
-- to act on it -- exactly the distinction this schema has drawn everywhere
-- else.
--
-- can_see_work_item() is the single choke point almost everything else's
-- visibility already runs through: work_items_select, tasks_select,
-- submissions_select, files_select, approvals_select, po_requests_select,
-- comments_select and activity_log_select (0006_rls.sql) all OR it in. The
-- Control Tower's own metrics RPCs (0009_metrics.sql) are SECURITY INVOKER
-- and query through it too. So widening this one function is enough --
-- nothing else needs editing at the RLS layer.
--
-- One real side effect, not a bug: po_requests_insert (0023) gated
-- self-attributing a PO on the work item actually being visible to the
-- raiser, specifically to stop a blind insert against an item you have no
-- connection to. With visibility now universal, that clause is trivially
-- true for everyone -- so any signed-in user can now raise a PO against any
-- work item by naming themselves raised_by, not just one they'd have
-- otherwise been able to see. The remaining protection there (work_item_id
-- must be a real, non-NULL item) still holds. If that turns out to be too
-- broad, it needs its own decision, not a workaround buried in this file.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.can_see_work_item(p_work_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL;
$$;


-- ####### 0026_task_control_restricted.sql #######

-- ============================================================================
-- 0026_task_control_restricted.sql — controlling the task list is Nirmal,
--   Vijaya, and ADMIN only
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Product decision: the task list ("to do list") is visible to everyone
-- (0025), but ADDING a task, REASSIGNING one off someone, or DELETING one is
-- restricted to exactly Nirmal and Vijaya -- who already hold
-- STATUS_CONTROLLER for this exact reason (0015/0021/0022 already reserve
-- moving work between stages to them). ADMIN keeps its standing full-
-- administration override, same as every other permission narrowed this
-- project (0020's job-creation restriction, 0022's edit override) --
-- public.can_change_status() already folds ADMIN in via its change_status
-- permission, so this needs no separate ADMIN clause.
--
-- Per this codebase's own rule ("Every stage points at a ROLE, never a
-- person" -- 0012; "resolved from approval_authorities... never a constant
-- in code" -- 0016), this is wired through the STATUS_CONTROLLER role /
-- can_change_status(), not Nirmal's or Vijaya's names or emails.
--
-- THE ACTUAL GAP (found by reading 0013_admin_task_controls.sql, then
-- confirmed by testing, not by reading alone):
--
-- add_task_to_work_item() / reassign_work_item() / remove_task() are
-- SECURITY INVOKER with their own internal has_role() check -- 0013's own
-- header says that check is "a friendlier error message, not the boundary;
-- a caller without the role gets refused by the GRANT/policy regardless."
-- Narrowing only those internal checks would not have been enough:
--
--   * tasks_update had its own independent role list with no
--     can_change_status() branch at all. reassign_work_item's very first
--     write is an UPDATE on the OLD task row (closing it) -- a pure
--     STATUS_CONTROLLER would have hit the exact same "RLS silently
--     matches zero rows" failure this session already found twice on the
--     PO fixes, immediately after passing the widened function-level check.
--   * tasks_delete was ADMIN-only with no can_change_status() branch --
--     same problem for remove_task.
--   * tasks_insert's own top-level role list (ADMIN/WORKFLOW_MANAGER/
--     COORDINATOR) was a gap in the OTHER direction: Sushant holds
--     COORDINATOR (0011) but not STATUS_CONTROLLER, so he could insert into
--     tasks directly via the client, bypassing a narrowed
--     add_task_to_work_item() entirely. can_edit_work_item() already covers
--     everything tasks_insert actually needs (ADMIN, WORKFLOW_MANAGER,
--     can_change_status(), and -- critically -- the item's own current
--     holder, which normal handoffs like submit_for_next_stage depend on to
--     create the NEXT task), so the redundant top-level list is dropped
--     rather than patched.
-- ============================================================================

DROP POLICY IF EXISTS tasks_insert ON public.tasks;
CREATE POLICY tasks_insert ON public.tasks FOR INSERT TO authenticated
  WITH CHECK (public.can_edit_work_item(work_item_id));

DROP POLICY IF EXISTS tasks_update ON public.tasks;
CREATE POLICY tasks_update ON public.tasks FOR UPDATE TO authenticated
  USING (assignee_id = auth.uid() OR public.can_change_status())
  WITH CHECK (assignee_id = auth.uid() OR public.can_change_status());

DROP POLICY IF EXISTS tasks_delete ON public.tasks;
CREATE POLICY tasks_delete ON public.tasks FOR DELETE TO authenticated
  USING (public.can_change_status());


CREATE OR REPLACE FUNCTION public.reassign_work_item(
  p_work_item_id     UUID,
  p_new_assignee_id  UUID,
  p_note             TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor              UUID := auth.uid();
  v_work               public.work_items%ROWTYPE;
  v_stage              public.workflow_stages%ROWTYPE;
  v_old_assignee_name  TEXT;
  v_new_assignee_name  TEXT;
  v_deadline           DATE;
  v_task_id            UUID;
  v_action_type        TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.can_change_status() THEN
    RAISE EXCEPTION 'Only a status controller or admin can reassign work' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot be reassigned', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before reassigning.'
      USING ERRCODE = '22023';
  END IF;

  IF v_work.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = p_new_assignee_id AND is_active
  ) THEN
    RAISE EXCEPTION 'That person is not a known, active user' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;

  SELECT full_name INTO v_old_assignee_name
  FROM public.users WHERE id = v_work.current_assignee_id;
  SELECT full_name INTO v_new_assignee_name
  FROM public.users WHERE id = p_new_assignee_id;

  UPDATE public.tasks
  SET status = 'CANCELLED', closed_at = NOW(),
      closed_reason = format('Reassigned to %s%s',
                              v_new_assignee_name,
                              CASE WHEN p_note IS NOT NULL THEN ': ' || p_note ELSE '' END)
  WHERE work_item_id = p_work_item_id
    AND stage_id = v_work.current_stage_id
    AND closed_at IS NULL;

  v_deadline    := public.compute_stage_deadline(v_work.current_stage_id, v_work.priority);
  v_action_type := CASE WHEN v_stage.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END;

  INSERT INTO public.tasks (
    work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
    action_type, priority, due_date
  ) VALUES (
    p_work_item_id, v_work.current_stage_id, p_new_assignee_id, v_actor,
    format('%s — %s', v_work.name, v_stage.name), p_note,
    v_action_type, v_work.priority, v_deadline
  ) RETURNING id INTO v_task_id;

  UPDATE public.work_items
  SET current_assignee_id = p_new_assignee_id,
      pending_with_id     = p_new_assignee_id,
      pending_with_label  = NULL,
      status              = 'IN_PROGRESS',
      stage_deadline      = v_deadline,
      handoff_at          = NOW(),
      handoff_by          = v_actor
  WHERE id = p_work_item_id;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'REASSIGNED',
          COALESCE(v_old_assignee_name, 'unassigned'), v_new_assignee_name,
          jsonb_build_object('note', p_note));

  INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
  VALUES (p_new_assignee_id, p_work_item_id, v_task_id, 'ASSIGNMENT',
          format('Reassigned to you: %s', v_work.name),
          format('Stage: %s.%s', v_stage.name,
                 CASE WHEN p_note IS NOT NULL THEN ' ' || p_note ELSE '' END),
          '/work/' || p_work_item_id);

  RETURN jsonb_build_object(
    'reassigned', TRUE,
    'stage', v_stage.name,
    'new_assignee_id', p_new_assignee_id,
    'new_assignee_name', v_new_assignee_name,
    'task_id', v_task_id
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.add_task_to_work_item(
  p_work_item_id UUID,
  p_assignee_id  UUID,
  p_note         TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor         UUID := auth.uid();
  v_work          public.work_items%ROWTYPE;
  v_stage         public.workflow_stages%ROWTYPE;
  v_assignee_name TEXT;
  v_deadline      DATE;
  v_task_id       UUID;
  v_action_type   TEXT;
  v_had_holder    BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.can_change_status() THEN
    RAISE EXCEPTION 'Only a status controller or admin can add a task' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot take a new task', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before adding a task.'
      USING ERRCODE = '22023';
  END IF;

  IF v_work.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = p_assignee_id AND is_active
  ) THEN
    RAISE EXCEPTION 'That person is not a known, active user' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.tasks
    WHERE work_item_id = p_work_item_id AND assignee_id = p_assignee_id
      AND stage_id = v_work.current_stage_id AND closed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'This person already has an open task at this stage' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;
  SELECT full_name INTO v_assignee_name FROM public.users WHERE id = p_assignee_id;

  v_deadline    := public.compute_stage_deadline(v_work.current_stage_id, v_work.priority);
  v_action_type := CASE WHEN v_stage.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END;

  INSERT INTO public.tasks (
    work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
    action_type, priority, due_date
  ) VALUES (
    p_work_item_id, v_work.current_stage_id, p_assignee_id, v_actor,
    format('%s — %s', v_work.name, v_stage.name), p_note,
    v_action_type, v_work.priority, v_deadline
  ) RETURNING id INTO v_task_id;

  v_had_holder := v_work.current_assignee_id IS NOT NULL;

  IF NOT v_had_holder THEN
    UPDATE public.work_items
    SET current_assignee_id = p_assignee_id,
        pending_with_id     = p_assignee_id,
        pending_with_label  = NULL,
        status              = 'IN_PROGRESS',
        stage_deadline      = v_deadline,
        handoff_at          = NOW(),
        handoff_by          = v_actor
    WHERE id = p_work_item_id;
  END IF;

  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role, assigned_by)
  VALUES (p_work_item_id, p_assignee_id, 'SUPPORT', v_actor)
  ON CONFLICT (work_item_id, user_id) DO NOTHING;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'TASK_ADDED', v_assignee_name,
          jsonb_build_object('note', p_note, 'stage', v_stage.name));

  INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
  VALUES (p_assignee_id, p_work_item_id, v_task_id, 'ASSIGNMENT',
          format('New task: %s', v_work.name),
          format('Stage: %s.%s', v_stage.name,
                 CASE WHEN p_note IS NOT NULL THEN ' ' || p_note ELSE '' END),
          '/work/' || p_work_item_id);

  RETURN jsonb_build_object(
    'added', TRUE,
    'task_id', v_task_id,
    'assignee_name', v_assignee_name,
    'became_holder', NOT v_had_holder
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.remove_task(
  p_task_id UUID,
  p_reason  TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor     UUID := auth.uid();
  v_task      public.tasks%ROWTYPE;
  v_remaining INT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.can_change_status() THEN
    RAISE EXCEPTION 'Only a status controller or admin can delete a task' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_task.closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This task is already closed' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
  VALUES (v_task.work_item_id, v_actor, 'TASK_REMOVED',
          jsonb_build_object('title', v_task.title, 'assignee_id', v_task.assignee_id,
                             'reason', p_reason));

  DELETE FROM public.tasks WHERE id = p_task_id;

  SELECT COUNT(*) INTO v_remaining
  FROM public.tasks
  WHERE work_item_id = v_task.work_item_id AND closed_at IS NULL;

  IF v_remaining = 0 THEN
    UPDATE public.work_items
    SET current_assignee_id = NULL,
        pending_with_id     = NULL,
        pending_with_label  = 'unassigned',
        status              = CASE
                                 WHEN status IN ('ON_HOLD','COMPLETED','CANCELLED','REJECTED')
                                 THEN status ELSE 'PENDING' END
    WHERE id = v_task.work_item_id;
  END IF;

  RETURN jsonb_build_object(
    'removed', TRUE,
    'work_item_id', v_task.work_item_id,
    'cleared_assignment', v_remaining = 0
  );
END;
$$;


-- ####### 0027_anshika_also_designer.sql #######

-- ============================================================================
-- 0027_anshika_also_designer.sql — Anshika also holds DESIGNER
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Additive: Anshika (anshika.pundhir@shardacare.com, VIDEO_EDITOR since 0024)
-- also gets DESIGNER, alongside her existing role rather than in place of it.
-- Matched on her real email, not full_name, for the same reason as 0024 --
-- avoids any ambiguity if another person ever shares a first name.
--
-- Practical effect: she becomes eligible for the DESIGN stage's
-- auto-assignment (workflow_stages.expected_role_id for DESIGN -> DESIGNER;
-- resolve_next_assignee() picks from work_item_owners holding that role),
-- and shows up under "Designer" in TeamRoster.tsx's role grouping in
-- addition to "Video editor" -- no app code changes needed, it groups by
-- whatever roles a person actually holds.
-- ============================================================================

INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE u.email = 'anshika.pundhir@shardacare.com' AND r.name = 'DESIGNER'
ON CONFLICT (user_id, role_id) DO NOTHING;


-- ####### 0028_vidisha_also_social_media.sql #######

-- ============================================================================
-- 0028_vidisha_also_social_media.sql — Vidisha also holds SOCIAL_MEDIA
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Additive: Vidisha (from 0011, "Canva designer", DESIGNER only) also gets
-- SOCIAL_MEDIA, alongside her existing role rather than in place of it.
--
-- Matched on full_name = 'Vidisha', mirroring 0011's own DO block for the
-- same person, because -- unlike Anshika (0024, given a real email) --
-- Vidisha has no real email yet: she's still vidisha@placeholder.invalid.
--
-- Practical effect: the RELEASE stage's expected_role_id is SOCIAL_MEDIA
-- (0012: "Indu posts it on social media"), so she becomes eligible for its
-- auto-assignment; and shows up under "Social media" in TeamRoster.tsx's
-- role grouping in addition to "Designer" -- no app code changes needed, it
-- groups by whatever roles a person actually holds.
-- ============================================================================

INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE u.full_name = 'Vidisha' AND r.name = 'SOCIAL_MEDIA'
ON CONFLICT (user_id, role_id) DO NOTHING;


-- ####### 0029_vijaya_content_writer.sql #######

-- ============================================================================
-- 0029_vijaya_content_writer.sql — Vijaya (drvijayadutta@gmail.com) also
--   holds CONTENT_WRITER
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- 0017_creative_chain.sql already matched this exact identity --
--   lower(full_name) = 'vijaya' OR lower(email) = 'drvijayadutta@gmail.com'
-- -- to grant the proofread-APPROVER role, with its own comment noting "the
-- person who logs in as Vijaya may not be the same row as the 'Vijaya' the
-- job list imported." That block only granted APPROVER (the proofread
-- gate); it never granted CONTENT_WRITER, which is what the CONCEPT and
-- CONTENT stages actually route to (0012/0017: deliberately the same role
-- for both -- "no separate 'concept' role was named, and inventing one
-- would create a role nobody holds"). So the account could approve/
-- proofread, but was never eligible for the Content picker on New Work, or
-- for CONCEPT/CONTENT/CONTENT_REVIEW stage auto-assignment -- same "missing
-- from the dropdown" symptom as Vidisha's case (0028), a different role.
--
-- Reuses 0017's matching expression verbatim, not a new convention.
-- ============================================================================

INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE (lower(btrim(u.full_name)) = 'vijaya' OR lower(u.email) = 'drvijayadutta@gmail.com')
  AND r.name = 'CONTENT_WRITER'
ON CONFLICT (user_id, role_id) DO NOTHING;


-- ####### 0030_soft_delete_imported_job_list.sql #######

-- ============================================================================
-- 0030_soft_delete_imported_job_list.sql — retire the 10th Sept job-list
--   import
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Soft-deletes (not hard-deletes) the 30 jobs and 38 work items originally
-- imported from the 10th Sept source document by app/scripts/build-seed.mjs
-- -- confirmed to identify exactly and only that data: jobs.source_ref LIKE
-- 'joblist:job:%' and work_items.source_ref LIKE 'joblist:item:%' are
-- populated ONLY by that import (see 0003_work.sql's own comment: "Nullable
-- ... hand-created jobs have none"), so nothing created through the app
-- itself matches these patterns.
--
-- Deliberately soft, not hard: every list/board/dashboard view already
-- filters deleted_at (v_work_items -- 0005_views.sql -- and everything that
-- reads through it: Control Tower metrics, Board, Work list, My Work), so
-- this is enough to make the import disappear from the app everywhere,
-- while staying recoverable (UPDATE ... SET deleted_at = NULL) if this
-- turns out to be a mistake -- a hard DELETE would cascade through tasks,
-- comments, files, activity_log, submissions, approvals and po_requests via
-- ON DELETE CASCADE and could not be undone.
--
-- Deliberately does NOT touch the 17 people the import also created
-- (public.users rows) -- several, like Anshika and Vidisha, have since been
-- given real emails and real discipline roles and are referenced by other
-- things; deleting the job list should not touch them.
--
-- Companion change: app/scripts/build-seed.mjs no longer emits jobs/work
-- items on a future run (people/roles/workflow-template setup is
-- unaffected), so a fresh install of this app won't re-import this list.
-- ============================================================================

UPDATE public.jobs
   SET deleted_at = NOW()
 WHERE source_ref LIKE 'joblist:job:%'
   AND deleted_at IS NULL;

UPDATE public.work_items
   SET deleted_at = NOW()
 WHERE source_ref LIKE 'joblist:item:%'
   AND deleted_at IS NULL;
