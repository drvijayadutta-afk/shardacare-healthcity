-- ============================================================================
-- 0019_work_item_journey.sql — the whole journey of a task, with names on it
-- ============================================================================
-- Stated by the team lead:
--   "for each task show the stages in pill format and entire journey should be
--    visible and name written on it that who is taking care of it"
--
-- The stepper already drew pills, but it drew STAGES — "Design", "Content
-- review" — and a stage name does not answer the question anybody actually
-- asks, which is "who has it, and who had it before that". The person was
-- shown once, for the current stage only, in a field lower down the page.
--
-- This view answers it for every stage at once. The tricky part is that
-- "who is taking care of it" means three different things depending on where
-- the stage sits:
--
--   already passed  — who ACTUALLY did it. Not who was supposed to: work gets
--                     reassigned, and the history should say what happened.
--   current         — who holds it right now.
--   still to come   — who it WILL route to, resolved the same way the engine
--                     will resolve it when it gets there (approval_authorities
--                     for a gate), so the pill and the future agree.
--
-- Where no person can be named — a future stage that routes by role rather
-- than to a registered approver — the view returns the ROLE and leaves the
-- name NULL, so the UI can say "a designer" rather than inventing a person.
--
-- Idempotent. Safe to run twice.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_work_item_journey
WITH (security_invoker = TRUE) AS
SELECT
  w.id                       AS work_item_id,
  s.id                       AS stage_id,
  s.name                     AS stage_name,
  s.stage_order,
  s.track,
  s.requires_approval,
  s.is_terminal,

  -- Where this stage sits relative to the work item's position.
  CASE
    WHEN cur.stage_order IS NULL              THEN 'upcoming'
    WHEN s.stage_order  <  cur.stage_order    THEN 'done'
    WHEN s.stage_order  =  cur.stage_order    THEN 'current'
    ELSE 'upcoming'
  END                        AS state,

  -- Who is taking care of it.
  COALESCE(
    -- Passed: whoever actually submitted or approved at this stage. Approvals
    -- first, because on a gate the approver's verdict is the event that
    -- mattered; the submission into the gate belongs to the stage before.
    approver.full_name,
    submitter.full_name,
    -- Current: the person holding it now.
    CASE WHEN s.stage_order = cur.stage_order
         THEN COALESCE(assignee.full_name, owner.full_name, w.pending_with_label)
    END,
    -- Upcoming gate: whoever the engine will route to when it arrives.
    gate_approver.full_name
  )                          AS person_name,

  COALESCE(approver.id, submitter.id,
           CASE WHEN s.stage_order = cur.stage_order
                THEN COALESCE(assignee.id, owner.id) END,
           gate_approver.id) AS person_id,

  -- The fallback when nobody can be named: what KIND of person holds it.
  r.name                     AS role_name,

  -- When it happened, for the tooltip on a completed pill.
  COALESCE(appr.decided_at, sub.submitted_at) AS acted_at

FROM public.work_items w
JOIN public.workflow_stages s
  ON s.workflow_id = w.workflow_id
LEFT JOIN public.workflow_stages cur
  ON cur.id = w.current_stage_id
LEFT JOIN public.roles r
  ON r.id = s.expected_role_id

-- The most recent approval given at this stage, for this item.
LEFT JOIN LATERAL (
  SELECT a.approver_id, a.decided_at
  FROM public.approvals a
  WHERE a.work_item_id = w.id AND a.stage_id = s.id
  ORDER BY a.decided_at DESC
  LIMIT 1
) appr ON TRUE
LEFT JOIN public.users approver ON approver.id = appr.approver_id

-- The most recent submission made from this stage, for this item.
LEFT JOIN LATERAL (
  SELECT sm.submitted_by, sm.submitted_at
  FROM public.submissions sm
  WHERE sm.work_item_id = w.id AND sm.stage_id = s.id
  ORDER BY sm.submitted_at DESC
  LIMIT 1
) sub ON TRUE
LEFT JOIN public.users submitter ON submitter.id = sub.submitted_by

LEFT JOIN public.users assignee ON assignee.id = w.current_assignee_id
LEFT JOIN public.users owner    ON owner.id    = w.owner_id

-- Who a future approval gate will route to. Lowest active level wins, which is
-- the same rule resolve_approver() uses, so the pill does not promise one
-- person and the engine then pick another.
LEFT JOIN LATERAL (
  SELECT u.id, u.full_name
  FROM public.approval_authorities aa
  JOIN public.users u ON u.id = aa.approver_id
  WHERE aa.is_active
    AND s.requires_approval
    AND aa.work_category = s.approval_category
  ORDER BY aa.approval_level, aa.created_at
  LIMIT 1
) gate_approver ON TRUE

-- Procurement stages belong to the parallel rail (0016) and are drawn
-- separately; on work that needs no PO they are not part of the journey at all.
WHERE s.track = 'MAIN' OR w.po_required;

GRANT SELECT ON public.v_work_item_journey TO authenticated;

COMMENT ON VIEW public.v_work_item_journey IS
  'One row per stage per work item: where it sits, and who is taking care of
   it — the person who actually did it for passed stages, the current holder
   for the current one, and the person the engine will route to for stages
   still to come.';
