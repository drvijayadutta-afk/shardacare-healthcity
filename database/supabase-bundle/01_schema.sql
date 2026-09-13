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
