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
