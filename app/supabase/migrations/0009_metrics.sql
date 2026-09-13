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
