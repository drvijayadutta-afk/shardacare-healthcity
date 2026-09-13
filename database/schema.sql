-- ============================================================================
-- SUPERSEDED — DO NOT RUN
--
-- This draft is invalid Postgres: it uses MySQL-style inline INDEX
-- declarations inside CREATE TABLE, so it aborts at the jobs table and
-- creates nothing after it. It also lacks security_invoker on its view and
-- leaves several tables with RLS enabled but no policy.
--
-- The working, executed-and-tested schema is app/supabase/migrations/.
-- Kept only for reference; safe to delete.
-- ============================================================================

-- ============================================================================
-- MARKETING WORKFLOW CONTROL TOWER - SUPABASE SCHEMA
-- ============================================================================
-- Fully configurable, no hardcoding of business logic
-- Row Level Security (RLS) enabled for multi-tenant safety
-- ============================================================================

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. USERS & AUTHENTICATION
-- ============================================================================

CREATE TABLE auth_users (
  id UUID PRIMARY KEY DEFAULT auth.uid(),
  email TEXT NOT NULL UNIQUE,
  full_name TEXT NOT NULL,
  avatar_url TEXT,
  phone TEXT,
  active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  last_login TIMESTAMP WITH TIME ZONE,
  FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE
);

CREATE TABLE user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_name VARCHAR(50) NOT NULL UNIQUE,
  description TEXT,
  permissions JSONB NOT NULL DEFAULT '[]',
  -- Example: ["create_work_items", "submit_for_approval", "view_own_work", ...]
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  CONSTRAINT valid_role_name CHECK (role_name ~ '^[A-Z_]+$')
);

CREATE TABLE user_role_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES user_roles(id),
  assigned_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  assigned_by_id UUID REFERENCES auth_users(id),
  UNIQUE (user_id, role_id)
);

-- Seed default roles (no hardcoding of names, but these defaults exist)
INSERT INTO user_roles (role_name, description, permissions) VALUES
  ('ADMIN', 'System administrator', '["manage_users","manage_workflows","view_all","override_approvals","access_audit"]'),
  ('WORKFLOW_MANAGER', 'Oversee workflows', '["view_all","reassign_work","modify_deadlines","escalate","access_reports"]'),
  ('APPROVER', 'Approve work items', '["view_assigned","approve_work","request_changes","add_comments"]'),
  ('CREATOR', 'Create work items', '["create_work","view_own","submit_work","respond_to_changes"]'),
  ('COORDINATOR', 'Manage work assignments', '["create_work","view_all_assigned","assign_work","track_progress"]'),
  ('REQUESTOR', 'Submit work requests', '["create_requests","view_own_requests"]'),
  ('VENDOR', 'External vendor', '["view_assigned","submit_deliverables","update_progress"]')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 2. ORGANIZATION & DEPARTMENTS (Configurable)
-- ============================================================================

CREATE TABLE departments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL UNIQUE,
  description TEXT,
  head_id UUID REFERENCES auth_users(id),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW())
);

CREATE TABLE approval_authorities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  approver_id UUID NOT NULL REFERENCES auth_users(id),
  work_category VARCHAR(100) NOT NULL,
  -- Examples: "campaign", "branding", "print", "vendor", "po"
  approval_level INT DEFAULT 1,
  -- 1 = initial approver, 2 = secondary, etc.
  budget_threshold_min DECIMAL(12, 2) DEFAULT 0,
  budget_threshold_max DECIMAL(12, 2) DEFAULT 999999999,
  -- Applies to this approver if work value falls in this range
  priority_applies_to VARCHAR(50),
  -- "ALL" | "HIGH" | "CRITICAL" - which priorities need this approver
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW())
);

-- ============================================================================
-- 3. WORKFLOW CONFIGURATION (Highly Configurable)
-- ============================================================================

CREATE TABLE workflow_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL UNIQUE,
  description TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  multi_owner_behavior VARCHAR(50) NOT NULL DEFAULT 'SINGLE',
  -- VALUES: 'SINGLE', 'PARALLEL', 'SEQUENTIAL', 'COLLABORATIVE'
  requires_po BOOLEAN DEFAULT FALSE,
  requires_final_approval BOOLEAN DEFAULT TRUE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW())
);

CREATE TABLE workflow_stages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID NOT NULL REFERENCES workflow_templates(id) ON DELETE CASCADE,
  stage_name VARCHAR(100) NOT NULL,
  -- Examples: "BRIEF", "CONTENT", "DESIGN", "INTERNAL_REVIEW", etc.
  stage_order INT NOT NULL,
  description TEXT,
  requires_approval BOOLEAN DEFAULT FALSE,
  requires_attachment BOOLEAN DEFAULT FALSE,
  attachment_types JSONB,
  -- ["pdf", "jpg", "figma_link"]
  expected_owner_role VARCHAR(50),
  -- "creator", "approver", "coordinator", "vendor", etc.
  sla_default_days INT DEFAULT 3,
  notify_on_entry BOOLEAN DEFAULT TRUE,
  notify_on_exit BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  UNIQUE (workflow_id, stage_order)
);

CREATE TABLE workflow_transitions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID NOT NULL REFERENCES workflow_templates(id) ON DELETE CASCADE,
  from_stage_id UUID NOT NULL REFERENCES workflow_stages(id),
  to_stage_id UUID REFERENCES workflow_stages(id),
  -- NULL means "end of workflow / completed"
  trigger_condition VARCHAR(100) NOT NULL,
  -- "SUBMISSION", "APPROVED", "CHANGES_REQUIRED", "REJECTED", "PO_RELEASED", "VENDOR_COMPLETE"
  description TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  UNIQUE (workflow_id, from_stage_id, trigger_condition)
);

CREATE TABLE stage_sla_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stage_id UUID NOT NULL REFERENCES workflow_stages(id) ON DELETE CASCADE,
  priority_level VARCHAR(20) NOT NULL,
  -- "CRITICAL", "HIGH", "MEDIUM", "LOW"
  sla_days INT NOT NULL,
  auto_escalate BOOLEAN DEFAULT FALSE,
  escalate_after_days INT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  UNIQUE (stage_id, priority_level)
);

-- ============================================================================
-- 4. JOBS (Parent Container)
-- ============================================================================

CREATE TABLE jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  category VARCHAR(100),
  -- Examples: "Marketing - Cardiac", "Branding - Clinic", "Print - Collateral"
  requester_id UUID NOT NULL REFERENCES auth_users(id),
  created_by_id UUID NOT NULL REFERENCES auth_users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  deleted_at TIMESTAMP WITH TIME ZONE,
  INDEX idx_requester (requester_id),
  INDEX idx_category (category),
  INDEX idx_created_at (created_at)
);

-- ============================================================================
-- 5. WORK ITEMS (Core Work Unit)
-- ============================================================================

CREATE TABLE work_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,

  -- Identity
  name VARCHAR(255) NOT NULL,
  description TEXT,

  -- Workflow
  workflow_id UUID NOT NULL REFERENCES workflow_templates(id),
  current_stage_id UUID REFERENCES workflow_stages(id),
  previous_stage_id UUID REFERENCES workflow_stages(id),

  -- Ownership
  requester_id UUID NOT NULL REFERENCES auth_users(id),
  owner_id UUID REFERENCES auth_users(id),
  current_assignee_id UUID REFERENCES auth_users(id),

  -- Pending With (answers "who does this need action from right now?")
  -- Distinct from current_assignee_id: the assignee is the accountable owner
  -- for the current stage, but pending_with is whoever's inbox the ball is
  -- actually sitting in (an approver, a vendor contact, or nobody resolvable
  -- yet from the source data). pending_with_id is set when that person is a
  -- known system user; pending_with_label carries free text (e.g. "unknown",
  -- "Vendor - Nirmal's contact") when the source data didn't name a resolvable
  -- person -- required by the seed script's "pending_with = unknown" rule.
  pending_with_id UUID REFERENCES auth_users(id),
  pending_with_label VARCHAR(255),

  -- Status
  status VARCHAR(50) NOT NULL DEFAULT 'NOT_STARTED',
  -- VALUES: 'NOT_STARTED', 'IN_PROGRESS', 'SUBMITTED', 'PENDING',
  --         'APPROVED', 'CHANGES_REQUIRED', 'REJECTED', 'BLOCKED', 'ON_HOLD', 'COMPLETED'
  substatus VARCHAR(100),
  -- Clarification: "waiting_on_vendor", "awaiting_budget", etc.

  -- Deadlines
  deadline DATE NOT NULL,
  stage_deadline DATE,

  -- Priority
  priority VARCHAR(20) NOT NULL DEFAULT 'MEDIUM',
  -- VALUES: 'CRITICAL', 'HIGH', 'MEDIUM', 'LOW'

  -- Dependencies
  depends_on_ids UUID[] DEFAULT ARRAY[]::uuid[],
  blocked_by_id UUID REFERENCES work_items(id),
  blocker_type VARCHAR(50),
  -- 'approval', 'vendor', 'budget', 'external', 'info_needed', 'other'
  blocker_owner_id UUID REFERENCES auth_users(id),

  -- Approvals
  approval_required BOOLEAN DEFAULT FALSE,
  approval_status VARCHAR(50) DEFAULT 'NOT_REQUIRED',
  -- VALUES: 'NOT_REQUIRED', 'PENDING', 'APPROVED', 'CHANGES_REQUIRED', 'REJECTED'

  -- PO Management
  po_required BOOLEAN DEFAULT FALSE,
  po_id UUID,
  po_status VARCHAR(50) DEFAULT 'NOT_REQUIRED',

  -- Campaign (if part of larger campaign)
  campaign_id UUID,
  deliverable_type VARCHAR(100),
  -- "email", "flyer", "banner", "video", etc.
  deliverable_sequence INT,
  release_date DATE,
  channels JSONB,
  -- ["email", "social", "print"]

  -- Tracking
  created_by_id UUID NOT NULL REFERENCES auth_users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  completed_at TIMESTAMP WITH TIME ZONE,
  deleted_at TIMESTAMP WITH TIME ZONE,

  -- Notifications
  last_notified_at TIMESTAMP WITH TIME ZONE,
  handoff_at TIMESTAMP WITH TIME ZONE,
  handoff_by_id UUID REFERENCES auth_users(id),

  -- Audit
  submission_count INT DEFAULT 0,
  current_submission_id UUID,

  CONSTRAINT valid_status CHECK (status IN ('NOT_STARTED', 'IN_PROGRESS', 'SUBMITTED', 'PENDING', 'APPROVED', 'CHANGES_REQUIRED', 'REJECTED', 'BLOCKED', 'ON_HOLD', 'COMPLETED')),
  INDEX idx_job (job_id),
  INDEX idx_owner (owner_id),
  INDEX idx_current_assignee (current_assignee_id),
  INDEX idx_stage (current_stage_id),
  INDEX idx_status (status),
  INDEX idx_deadline (deadline),
  INDEX idx_priority (priority),
  INDEX idx_created_at (created_at)
);

-- ============================================================================
-- 6. WORK ITEM OWNERS (Multi-Owner Handling)
-- ============================================================================

CREATE TABLE work_item_owners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
  owner_id UUID NOT NULL REFERENCES auth_users(id),
  role VARCHAR(50) NOT NULL DEFAULT 'PRIMARY',
  -- VALUES: 'PRIMARY', 'COLLABORATOR', 'SUPPORT', 'SEQUENTIAL_NEXT'
  sequence_order INT,
  -- For sequential hand-offs: order of progression
  submission_status VARCHAR(50) DEFAULT 'PENDING',
  -- VALUES: 'PENDING', 'SUBMITTED', 'APPROVED'
  submission_at TIMESTAMP WITH TIME ZONE,
  assigned_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  assigned_by_id UUID REFERENCES auth_users(id),
  UNIQUE (work_id, owner_id),
  INDEX idx_work (work_id),
  INDEX idx_owner (owner_id)
);

-- ============================================================================
-- 7. SUBMISSIONS & VERSIONS
-- ============================================================================

CREATE TABLE submissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
  submission_number INT NOT NULL,
  submitted_by_id UUID NOT NULL REFERENCES auth_users(id),
  submitted_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  submission_data JSONB,
  -- Snapshot of work item state at submission time
  notes TEXT,
  -- Submitter's comments
  UNIQUE (work_id, submission_number),
  INDEX idx_work (work_id),
  INDEX idx_submitted_at (submitted_at)
);

-- ============================================================================
-- 8. FILE ATTACHMENTS
-- ============================================================================

CREATE TABLE files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
  submission_id UUID REFERENCES submissions(id) ON DELETE SET NULL,

  original_filename VARCHAR(500) NOT NULL,
  stored_filename VARCHAR(500) NOT NULL,
  -- Actual filename in storage
  file_type VARCHAR(50),
  -- "pdf", "jpg", "psd", "figma_link", etc.
  file_size_bytes BIGINT,
  storage_path VARCHAR(1000),
  -- s3://bucket/path or similar

  uploaded_by_id UUID NOT NULL REFERENCES auth_users(id),
  uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),

  INDEX idx_work (work_id),
  INDEX idx_submission (submission_id),
  INDEX idx_uploaded_at (uploaded_at)
);

-- ============================================================================
-- 9. APPROVALS
-- ============================================================================

CREATE TABLE approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
  approver_id UUID NOT NULL REFERENCES auth_users(id),
  stage_id UUID NOT NULL REFERENCES workflow_stages(id),

  outcome VARCHAR(50) NOT NULL,
  -- VALUES: 'APPROVED', 'CHANGES_REQUIRED', 'REJECTED'
  reason TEXT,
  conditions JSONB,
  -- Additional approval conditions

  approved_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),

  INDEX idx_work (work_id),
  INDEX idx_approver (approver_id),
  INDEX idx_stage (stage_id)
);

-- ============================================================================
-- 10. PO REQUESTS (Configurable Procurement)
-- ============================================================================

CREATE TABLE po_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID REFERENCES work_items(id) ON DELETE SET NULL,

  po_number VARCHAR(100) UNIQUE,
  vendor_name VARCHAR(255),
  vendor_email VARCHAR(255),
  vendor_contact_id UUID REFERENCES auth_users(id),

  amount DECIMAL(12, 2) NOT NULL,
  currency VARCHAR(10) DEFAULT 'INR',

  description TEXT,

  status VARCHAR(50) NOT NULL DEFAULT 'DRAFT',
  -- VALUES: 'DRAFT', 'SUBMITTED', 'APPROVED', 'REJECTED', 'RELEASED', 'COMPLETED'
  approval_status VARCHAR(50) DEFAULT 'PENDING',

  created_by_id UUID NOT NULL REFERENCES auth_users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  submitted_at TIMESTAMP WITH TIME ZONE,
  approved_by_id UUID REFERENCES auth_users(id),
  approved_at TIMESTAMP WITH TIME ZONE,
  released_at TIMESTAMP WITH TIME ZONE,

  INDEX idx_work (work_id),
  INDEX idx_vendor (vendor_contact_id),
  INDEX idx_status (status)
);

-- ============================================================================
-- 11. COMMENTS & COLLABORATION
-- ============================================================================

CREATE TABLE comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
  author_id UUID NOT NULL REFERENCES auth_users(id),

  content TEXT NOT NULL,
  type VARCHAR(50) DEFAULT 'COMMENT',
  -- VALUES: 'COMMENT', 'CHANGE_REQUEST', 'APPROVAL_NOTE', 'STATUS_UPDATE'

  is_resolved BOOLEAN DEFAULT FALSE,
  resolved_at TIMESTAMP WITH TIME ZONE,
  resolved_by_id UUID REFERENCES auth_users(id),

  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),

  INDEX idx_work (work_id),
  INDEX idx_author (author_id),
  INDEX idx_type (type)
);

-- ============================================================================
-- 12. ACTIVITY LOG (Complete Audit Trail)
-- ============================================================================

CREATE TABLE activity_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,

  action_type VARCHAR(100) NOT NULL,
  -- Examples: 'CREATED', 'SUBMITTED', 'APPROVED', 'ASSIGNED',
  --           'STAGE_CHANGED', 'DEADLINE_CHANGED', 'BLOCKED', 'UNBLOCKED'

  actor_id UUID NOT NULL REFERENCES auth_users(id),
  action_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),

  details JSONB,
  -- Flexible object with action-specific details

  change_from VARCHAR(500),
  change_to VARCHAR(500),
  -- For tracking field changes

  INDEX idx_work (work_id),
  INDEX idx_actor (actor_id),
  INDEX idx_action_type (action_type),
  INDEX idx_action_at (action_at)
);

-- ============================================================================
-- 13. NOTIFICATIONS
-- ============================================================================

CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id UUID NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
  work_id UUID REFERENCES work_items(id) ON DELETE CASCADE,

  notification_type VARCHAR(100) NOT NULL,
  -- VALUES: 'ASSIGNMENT', 'APPROVAL_REQUIRED', 'CHANGES_REQUIRED',
  --         'OVERDUE_WARNING', 'OVERDUE', 'SUBMITTED', 'APPROVED'

  subject VARCHAR(255),
  message TEXT,

  sent_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
  read_at TIMESTAMP WITH TIME ZONE,

  action_url VARCHAR(500),
  -- Deep link to work item

  channel VARCHAR(50) DEFAULT 'EMAIL',
  -- 'EMAIL', 'IN_APP', 'SMS', 'SLACK'

  INDEX idx_recipient (recipient_id),
  INDEX idx_work (work_id),
  INDEX idx_sent_at (sent_at),
  INDEX idx_read_at (read_at)
);

-- ============================================================================
-- 14. VIEWS FOR COMMON QUERIES
-- ============================================================================

-- View: Work items with stage info and calculated fields
CREATE VIEW v_work_items_detailed AS
SELECT
  w.id,
  w.job_id,
  j.name AS job_name,
  j.category AS job_category,
  w.campaign_id,
  w.name,
  w.description,
  w.status,
  w.substatus,
  w.priority,
  w.current_stage_id,
  s.stage_name,
  s.stage_order,
  w.deadline,
  w.stage_deadline,
  CASE
    WHEN w.stage_deadline IS NULL THEN NULL
    WHEN w.stage_deadline < CURRENT_DATE THEN -(CURRENT_DATE - w.stage_deadline)
    ELSE (w.stage_deadline - CURRENT_DATE)
  END AS days_remaining,
  CASE
    WHEN w.stage_deadline IS NULL THEN FALSE
    ELSE CURRENT_DATE > w.stage_deadline AND w.status NOT IN ('COMPLETED', 'REJECTED')
  END AS is_overdue,
  w.owner_id,
  u1.full_name AS owner_name,
  w.current_assignee_id,
  u2.full_name AS current_assignee_name,
  w.pending_with_id,
  COALESCE(u3.full_name, w.pending_with_label) AS pending_with_display,
  w.approval_required,
  w.approval_status,
  w.po_required,
  w.po_status,
  w.blocked_by_id,
  w.blocker_type,
  wt.id AS workflow_id,
  wt.name AS workflow_name
FROM work_items w
LEFT JOIN jobs j ON w.job_id = j.id
LEFT JOIN workflow_stages s ON w.current_stage_id = s.id
LEFT JOIN auth_users u1 ON w.owner_id = u1.id
LEFT JOIN auth_users u2 ON w.current_assignee_id = u2.id
LEFT JOIN auth_users u3 ON w.pending_with_id = u3.id
LEFT JOIN workflow_templates wt ON w.workflow_id = wt.id
WHERE w.deleted_at IS NULL;

-- ============================================================================
-- 15. ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

-- Enable RLS on all tables
ALTER TABLE auth_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_item_owners ENABLE ROW LEVEL SECURITY;
ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE files ENABLE ROW LEVEL SECURITY;
ALTER TABLE approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE po_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- RLS POLICY: auth_users - Users can see own profile + team members
-- ============================================================================

CREATE POLICY "auth_users_select_own_or_team" ON auth_users
  FOR SELECT
  USING (
    auth.uid() = id
    OR EXISTS (
      SELECT 1 FROM user_role_assignments ura
      WHERE ura.user_id = auth.uid()
      AND ura.role_id IN (
        SELECT id FROM user_roles WHERE role_name IN ('ADMIN', 'WORKFLOW_MANAGER', 'COORDINATOR')
      )
    )
  );

CREATE POLICY "auth_users_update_own" ON auth_users
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- ============================================================================
-- RLS POLICY: work_items - Users see own + assigned + relevant work
-- ============================================================================

CREATE POLICY "work_items_select_own_or_assigned" ON work_items
  FOR SELECT
  USING (
    -- Own work
    owner_id = auth.uid()
    OR current_assignee_id = auth.uid()
    OR created_by_id = auth.uid()
    -- Managers can see all
    OR EXISTS (
      SELECT 1 FROM user_role_assignments ura
      JOIN user_roles ur ON ura.role_id = ur.id
      WHERE ura.user_id = auth.uid()
      AND ur.role_name IN ('ADMIN', 'WORKFLOW_MANAGER', 'COORDINATOR')
    )
  );

CREATE POLICY "work_items_update_own" ON work_items
  FOR UPDATE
  USING (
    owner_id = auth.uid()
    OR current_assignee_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM user_role_assignments ura
      JOIN user_roles ur ON ura.role_id = ur.id
      WHERE ura.user_id = auth.uid()
      AND ur.role_name IN ('ADMIN', 'WORKFLOW_MANAGER')
    )
  );

-- ============================================================================
-- RLS POLICY: submissions - Users see own submissions + assigned work
-- ============================================================================

CREATE POLICY "submissions_select_own" ON submissions
  FOR SELECT
  USING (
    submitted_by_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM work_items
      WHERE id = work_id
      AND (owner_id = auth.uid() OR current_assignee_id = auth.uid())
    )
  );

-- ============================================================================
-- RLS POLICY: approvals - Approvers see relevant approvals
-- ============================================================================

CREATE POLICY "approvals_select_relevant" ON approvals
  FOR SELECT
  USING (
    approver_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM work_items
      WHERE id = work_id
      AND (owner_id = auth.uid() OR created_by_id = auth.uid())
    )
  );

-- ============================================================================
-- INDEXES for Performance
-- ============================================================================

CREATE INDEX idx_work_items_owner ON work_items(owner_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_work_items_assignee ON work_items(current_assignee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_work_items_stage_status ON work_items(current_stage_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_work_items_deadline_priority ON work_items(deadline, priority) WHERE deleted_at IS NULL;
CREATE INDEX idx_work_item_owners_work_owner ON work_item_owners(work_id, owner_id);
CREATE INDEX idx_activity_log_work_time ON activity_log(work_id, action_at DESC);
CREATE INDEX idx_notifications_recipient_read ON notifications(recipient_id, read_at) WHERE read_at IS NULL;
CREATE INDEX idx_approvals_work_stage ON approvals(work_id, stage_id);

-- ============================================================================
-- GRANTS (Security)
-- ============================================================================

-- Service role can do everything (for backend operations)
-- Individual users: controlled by RLS policies

GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
