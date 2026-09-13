-- ============================================================================
-- 0013_admin_task_controls.sql — manual reassignment and task removal
-- ============================================================================
-- The audit that reviewed this app flagged a real gap: work_items_update
-- already lets ADMIN/WORKFLOW_MANAGER edit any work item, tasks_delete already
-- lets ADMIN delete any task, and the MANAGER role has carried the
-- 'reassign_work' permission since 0001 -- but nothing in the application
-- actually called these. The only way to move a person's work off them, or
-- correct a wrongly-created task, was a WORKFLOW_MANAGER editing rows by hand
-- in the Supabase table editor.
--
-- Same discipline as 0007_handoff.sql: a manual reassignment touches tasks,
-- work_items, activity_log and notifications together, so it is one
-- SECURITY INVOKER function rather than several round trips from the client
-- that could half-apply. SECURITY INVOKER means RLS still applies -- the role
-- check below is a friendlier error message, not the boundary; a caller
-- without the role gets refused by the GRANT/policy regardless.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- reassign_work_item — move the current stage to a different person.
--
-- This is an override of the normal handoff, not a thing the current holder
-- does to themselves (that is submit_for_next_stage). It works whether or not
-- anyone currently holds the item, which is what makes it double as the fix
-- for the 20-odd imported items with no assignee: opening one and reassigning
-- it puts a real task in the new owner's queue exactly as if the engine had
-- routed it there.
-- ----------------------------------------------------------------------------
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

  IF NOT public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']) THEN
    RAISE EXCEPTION 'Only an admin or workflow manager can reassign work' USING ERRCODE = '42501';
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

  -- Close whatever open task(s) currently represent this stage. Usually one,
  -- but PARALLEL/SEQUENTIAL work can have more than one collaborator holding
  -- an open task at the same stage.
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

-- ----------------------------------------------------------------------------
-- add_task_to_work_item — hand someone a task without disturbing whoever
-- already holds the stage.
--
-- Distinct from reassign_work_item on purpose: reassign REPLACES the current
-- holder (closes their task, opens one for the new person). This ADDS one --
-- a helper, a second pair of eyes, someone who needs visibility -- so an
-- existing open task is left exactly as it was. On a currently-unassigned
-- item there is nothing to leave alone, so this one new task also becomes
-- the item's official handoff, same as reassign_work_item would.
-- ----------------------------------------------------------------------------
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

  IF NOT public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER']) THEN
    RAISE EXCEPTION 'Only an admin or workflow manager can add a task' USING ERRCODE = '42501';
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

  -- Whoever gets a task should show up as a collaborator, which is what the
  -- Work Detail page's "Collaborators" field actually reads from.
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

-- ----------------------------------------------------------------------------
-- remove_task — delete a task outright rather than closing it through a
-- normal handoff. Matches tasks_delete RLS exactly (ADMIN only): this is for
-- correcting a mistake (duplicate task, wrong person, imported cruft), not a
-- workflow action, so it does not appear in anyone's activity as a handoff --
-- just a TASK_REMOVED entry recording that it happened and why.
-- ----------------------------------------------------------------------------
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

  IF NOT public.has_role(ARRAY['ADMIN']) THEN
    RAISE EXCEPTION 'Only an admin can delete a task' USING ERRCODE = '42501';
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

  -- If nothing else has an open task on this work item, "Pending With" must
  -- say so honestly rather than keep pointing at someone whose task no longer
  -- exists.
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
