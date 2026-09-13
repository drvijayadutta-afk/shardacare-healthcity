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
