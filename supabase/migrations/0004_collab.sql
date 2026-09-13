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
