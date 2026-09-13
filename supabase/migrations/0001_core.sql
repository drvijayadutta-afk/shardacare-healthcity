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
