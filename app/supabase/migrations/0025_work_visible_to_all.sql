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
