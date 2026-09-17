-- ============================================================================
-- 0026_task_control_restricted.sql — controlling the task list is Nirmal,
--   Vijaya, and ADMIN only
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Product decision: the task list ("to do list") is visible to everyone
-- (0025), but ADDING a task, REASSIGNING one off someone, or DELETING one is
-- restricted to exactly Nirmal and Vijaya -- who already hold
-- STATUS_CONTROLLER for this exact reason (0015/0021/0022 already reserve
-- moving work between stages to them). ADMIN keeps its standing full-
-- administration override, same as every other permission narrowed this
-- project (0020's job-creation restriction, 0022's edit override) --
-- public.can_change_status() already folds ADMIN in via its change_status
-- permission, so this needs no separate ADMIN clause.
--
-- Per this codebase's own rule ("Every stage points at a ROLE, never a
-- person" -- 0012; "resolved from approval_authorities... never a constant
-- in code" -- 0016), this is wired through the STATUS_CONTROLLER role /
-- can_change_status(), not Nirmal's or Vijaya's names or emails.
--
-- THE ACTUAL GAP (found by reading 0013_admin_task_controls.sql, then
-- confirmed by testing, not by reading alone):
--
-- add_task_to_work_item() / reassign_work_item() / remove_task() are
-- SECURITY INVOKER with their own internal has_role() check -- 0013's own
-- header says that check is "a friendlier error message, not the boundary;
-- a caller without the role gets refused by the GRANT/policy regardless."
-- Narrowing only those internal checks would not have been enough:
--
--   * tasks_update had its own independent role list with no
--     can_change_status() branch at all. reassign_work_item's very first
--     write is an UPDATE on the OLD task row (closing it) -- a pure
--     STATUS_CONTROLLER would have hit the exact same "RLS silently
--     matches zero rows" failure this session already found twice on the
--     PO fixes, immediately after passing the widened function-level check.
--   * tasks_delete was ADMIN-only with no can_change_status() branch --
--     same problem for remove_task.
--   * tasks_insert's own top-level role list (ADMIN/WORKFLOW_MANAGER/
--     COORDINATOR) was a gap in the OTHER direction: Sushant holds
--     COORDINATOR (0011) but not STATUS_CONTROLLER, so he could insert into
--     tasks directly via the client, bypassing a narrowed
--     add_task_to_work_item() entirely. can_edit_work_item() already covers
--     everything tasks_insert actually needs (ADMIN, WORKFLOW_MANAGER,
--     can_change_status(), and -- critically -- the item's own current
--     holder, which normal handoffs like submit_for_next_stage depend on to
--     create the NEXT task), so the redundant top-level list is dropped
--     rather than patched.
-- ============================================================================

DROP POLICY IF EXISTS tasks_insert ON public.tasks;
CREATE POLICY tasks_insert ON public.tasks FOR INSERT TO authenticated
  WITH CHECK (public.can_edit_work_item(work_item_id));

DROP POLICY IF EXISTS tasks_update ON public.tasks;
CREATE POLICY tasks_update ON public.tasks FOR UPDATE TO authenticated
  USING (assignee_id = auth.uid() OR public.can_change_status())
  WITH CHECK (assignee_id = auth.uid() OR public.can_change_status());

DROP POLICY IF EXISTS tasks_delete ON public.tasks;
CREATE POLICY tasks_delete ON public.tasks FOR DELETE TO authenticated
  USING (public.can_change_status());


CREATE OR REPLACE FUNCTION public.reassign_work_item(
  p_work_item_id     UUID,
  p_new_assignee_id  UUID,
  p_note             TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor              UUID := auth.uid();
  v_work               public.work_items%ROWTYPE;
  v_stage              public.workflow_stages%ROWTYPE;
  v_old_assignee_name  TEXT;
  v_new_assignee_name  TEXT;
  v_deadline           DATE;
  v_task_id            UUID;
  v_action_type        TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.can_change_status() THEN
    RAISE EXCEPTION 'Only a status controller or admin can reassign work' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot be reassigned', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before reassigning.'
      USING ERRCODE = '22023';
  END IF;

  IF v_work.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = p_new_assignee_id AND is_active
  ) THEN
    RAISE EXCEPTION 'That person is not a known, active user' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;

  SELECT full_name INTO v_old_assignee_name
  FROM public.users WHERE id = v_work.current_assignee_id;
  SELECT full_name INTO v_new_assignee_name
  FROM public.users WHERE id = p_new_assignee_id;

  UPDATE public.tasks
  SET status = 'CANCELLED', closed_at = NOW(),
      closed_reason = format('Reassigned to %s%s',
                              v_new_assignee_name,
                              CASE WHEN p_note IS NOT NULL THEN ': ' || p_note ELSE '' END)
  WHERE work_item_id = p_work_item_id
    AND stage_id = v_work.current_stage_id
    AND closed_at IS NULL;

  v_deadline    := public.compute_stage_deadline(v_work.current_stage_id, v_work.priority);
  v_action_type := CASE WHEN v_stage.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END;

  INSERT INTO public.tasks (
    work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
    action_type, priority, due_date
  ) VALUES (
    p_work_item_id, v_work.current_stage_id, p_new_assignee_id, v_actor,
    format('%s — %s', v_work.name, v_stage.name), p_note,
    v_action_type, v_work.priority, v_deadline
  ) RETURNING id INTO v_task_id;

  UPDATE public.work_items
  SET current_assignee_id = p_new_assignee_id,
      pending_with_id     = p_new_assignee_id,
      pending_with_label  = NULL,
      status              = 'IN_PROGRESS',
      stage_deadline      = v_deadline,
      handoff_at          = NOW(),
      handoff_by          = v_actor
  WHERE id = p_work_item_id;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'REASSIGNED',
          COALESCE(v_old_assignee_name, 'unassigned'), v_new_assignee_name,
          jsonb_build_object('note', p_note));

  INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
  VALUES (p_new_assignee_id, p_work_item_id, v_task_id, 'ASSIGNMENT',
          format('Reassigned to you: %s', v_work.name),
          format('Stage: %s.%s', v_stage.name,
                 CASE WHEN p_note IS NOT NULL THEN ' ' || p_note ELSE '' END),
          '/work/' || p_work_item_id);

  RETURN jsonb_build_object(
    'reassigned', TRUE,
    'stage', v_stage.name,
    'new_assignee_id', p_new_assignee_id,
    'new_assignee_name', v_new_assignee_name,
    'task_id', v_task_id
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.add_task_to_work_item(
  p_work_item_id UUID,
  p_assignee_id  UUID,
  p_note         TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor         UUID := auth.uid();
  v_work          public.work_items%ROWTYPE;
  v_stage         public.workflow_stages%ROWTYPE;
  v_assignee_name TEXT;
  v_deadline      DATE;
  v_task_id       UUID;
  v_action_type   TEXT;
  v_had_holder    BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.can_change_status() THEN
    RAISE EXCEPTION 'Only a status controller or admin can add a task' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot take a new task', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before adding a task.'
      USING ERRCODE = '22023';
  END IF;

  IF v_work.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users WHERE id = p_assignee_id AND is_active
  ) THEN
    RAISE EXCEPTION 'That person is not a known, active user' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.tasks
    WHERE work_item_id = p_work_item_id AND assignee_id = p_assignee_id
      AND stage_id = v_work.current_stage_id AND closed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'This person already has an open task at this stage' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;
  SELECT full_name INTO v_assignee_name FROM public.users WHERE id = p_assignee_id;

  v_deadline    := public.compute_stage_deadline(v_work.current_stage_id, v_work.priority);
  v_action_type := CASE WHEN v_stage.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END;

  INSERT INTO public.tasks (
    work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
    action_type, priority, due_date
  ) VALUES (
    p_work_item_id, v_work.current_stage_id, p_assignee_id, v_actor,
    format('%s — %s', v_work.name, v_stage.name), p_note,
    v_action_type, v_work.priority, v_deadline
  ) RETURNING id INTO v_task_id;

  v_had_holder := v_work.current_assignee_id IS NOT NULL;

  IF NOT v_had_holder THEN
    UPDATE public.work_items
    SET current_assignee_id = p_assignee_id,
        pending_with_id     = p_assignee_id,
        pending_with_label  = NULL,
        status              = 'IN_PROGRESS',
        stage_deadline      = v_deadline,
        handoff_at          = NOW(),
        handoff_by          = v_actor
    WHERE id = p_work_item_id;
  END IF;

  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role, assigned_by)
  VALUES (p_work_item_id, p_assignee_id, 'SUPPORT', v_actor)
  ON CONFLICT (work_item_id, user_id) DO NOTHING;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'TASK_ADDED', v_assignee_name,
          jsonb_build_object('note', p_note, 'stage', v_stage.name));

  INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
  VALUES (p_assignee_id, p_work_item_id, v_task_id, 'ASSIGNMENT',
          format('New task: %s', v_work.name),
          format('Stage: %s.%s', v_stage.name,
                 CASE WHEN p_note IS NOT NULL THEN ' ' || p_note ELSE '' END),
          '/work/' || p_work_item_id);

  RETURN jsonb_build_object(
    'added', TRUE,
    'task_id', v_task_id,
    'assignee_name', v_assignee_name,
    'became_holder', NOT v_had_holder
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.remove_task(
  p_task_id UUID,
  p_reason  TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor     UUID := auth.uid();
  v_task      public.tasks%ROWTYPE;
  v_remaining INT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT public.can_change_status() THEN
    RAISE EXCEPTION 'Only a status controller or admin can delete a task' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_task.closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This task is already closed' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
  VALUES (v_task.work_item_id, v_actor, 'TASK_REMOVED',
          jsonb_build_object('title', v_task.title, 'assignee_id', v_task.assignee_id,
                             'reason', p_reason));

  DELETE FROM public.tasks WHERE id = p_task_id;

  SELECT COUNT(*) INTO v_remaining
  FROM public.tasks
  WHERE work_item_id = v_task.work_item_id AND closed_at IS NULL;

  IF v_remaining = 0 THEN
    UPDATE public.work_items
    SET current_assignee_id = NULL,
        pending_with_id     = NULL,
        pending_with_label  = 'unassigned',
        status              = CASE
                                 WHEN status IN ('ON_HOLD','COMPLETED','CANCELLED','REJECTED')
                                 THEN status ELSE 'PENDING' END
    WHERE id = v_task.work_item_id;
  END IF;

  RETURN jsonb_build_object(
    'removed', TRUE,
    'work_item_id', v_task.work_item_id,
    'cleared_assignment', v_remaining = 0
  );
END;
$$;
