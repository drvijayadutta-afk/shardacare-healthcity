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
