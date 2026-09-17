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
