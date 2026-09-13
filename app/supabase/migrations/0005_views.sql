-- ============================================================================
-- 0005_views.sql — Read models
-- ============================================================================
-- security_invoker = true is mandatory on every view here. Without it a view
-- executes with its OWNER's privileges and silently bypasses RLS on the
-- underlying tables, which would hand every user every row — the exact
-- opposite of "a user should see only tasks assigned to them".
-- ============================================================================

-- Dropped in reverse dependency order: v_my_tasks selects from v_work_items,
-- so dropping the base view first fails on any re-run. This file must stay
-- re-runnable — it is applied by pasting into the Supabase SQL Editor, which
-- people do repeatedly.
DROP VIEW IF EXISTS public.v_my_tasks;
DROP VIEW IF EXISTS public.v_work_items;

CREATE VIEW public.v_work_items WITH (security_invoker = true) AS
SELECT
  w.id,
  w.name,
  w.description,
  w.deliverable_type,

  w.job_id,
  j.name                AS job_name,
  j.category            AS job_category,
  j.campaign_id,
  c.name                AS campaign_name,

  w.workflow_id,
  wt.name               AS workflow_name,
  wt.multi_owner_behavior,
  w.current_stage_id,
  s.name                AS stage_name,
  s.stage_order,
  s.requires_approval   AS stage_requires_approval,
  s.is_terminal         AS stage_is_terminal,

  w.status,
  w.substatus,
  w.priority,

  w.owner_id,
  ow.full_name          AS owner_name,
  w.current_assignee_id,
  asg.full_name         AS assignee_name,

  w.pending_with_id,
  -- A single field the UI can render for "Pending With": the resolved user's
  -- name when we know them, else whatever the source told us (e.g. 'unknown').
  COALESCE(pw.full_name, w.pending_with_label) AS pending_with,

  w.deadline,
  w.stage_deadline,
  -- Days remaining counts against the stage deadline when one is set,
  -- otherwise the overall deadline. NULL when neither exists — an undated
  -- item shows "—", never a fabricated number.
  (COALESCE(w.stage_deadline, w.deadline) - CURRENT_DATE) AS days_remaining,
  (COALESCE(w.stage_deadline, w.deadline) IS NOT NULL
     AND COALESCE(w.stage_deadline, w.deadline) < CURRENT_DATE
     AND w.status NOT IN ('COMPLETED','CANCELLED','REJECTED'))     AS is_overdue,

  w.approval_required,
  w.approval_status,
  w.po_required,
  w.po_status,
  w.po_request_id,
  w.estimated_amount,

  w.blocked_by_id,
  w.blocker_type,
  w.blocker_note,

  w.needs_review,
  w.review_notes,
  w.source_text,

  w.submission_count,
  w.created_at,
  w.updated_at,
  w.completed_at
FROM public.work_items w
LEFT JOIN public.jobs               j   ON j.id  = w.job_id
LEFT JOIN public.campaigns          c   ON c.id  = j.campaign_id
LEFT JOIN public.workflow_templates wt  ON wt.id = w.workflow_id
LEFT JOIN public.workflow_stages    s   ON s.id  = w.current_stage_id
LEFT JOIN public.users              ow  ON ow.id = w.owner_id
LEFT JOIN public.users              asg ON asg.id= w.current_assignee_id
LEFT JOIN public.users              pw  ON pw.id = w.pending_with_id
WHERE w.deleted_at IS NULL;

-- ----------------------------------------------------------------------------
-- v_my_tasks — the My Work read model. One row per OPEN task assigned to the
-- caller.
--
-- The `assignee_id = auth.uid()` predicate below is REQUIRED and is not
-- redundant with RLS. The policy on `tasks` deliberately allows you to see
-- other people's tasks on work you are involved in — the Work Detail page
-- needs that to show who else is holding the item. So RLS alone answers
-- "tasks I may look at", which is a wider set than "tasks assigned to me".
-- Without this line an approver sees the designer's task in their own queue.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_my_tasks;
CREATE VIEW public.v_my_tasks WITH (security_invoker = true) AS
SELECT
  t.id                  AS task_id,
  t.work_item_id,
  t.assignee_id,
  t.title,
  t.instructions,
  t.action_type,
  t.status              AS task_status,
  t.priority            AS task_priority,
  t.due_date,
  t.opened_at,

  w.name                AS work_name,
  w.job_name,
  w.campaign_name,
  w.stage_name,
  w.stage_order,
  w.status              AS work_status,
  w.priority            AS work_priority,
  w.pending_with,
  w.owner_name,
  w.approval_status,
  w.po_status,

  COALESCE(t.due_date, w.stage_deadline, w.deadline)                    AS effective_due_date,
  (COALESCE(t.due_date, w.stage_deadline, w.deadline) - CURRENT_DATE)   AS days_remaining,
  (COALESCE(t.due_date, w.stage_deadline, w.deadline) IS NOT NULL
     AND COALESCE(t.due_date, w.stage_deadline, w.deadline) < CURRENT_DATE) AS is_overdue
FROM public.tasks t
JOIN public.v_work_items w ON w.id = t.work_item_id
WHERE t.closed_at IS NULL
  AND t.assignee_id = auth.uid();
