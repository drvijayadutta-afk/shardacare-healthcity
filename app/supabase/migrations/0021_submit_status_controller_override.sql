-- ============================================================================
-- 0021_submit_status_controller_override.sql
--   Let a STATUS_CONTROLLER (Vijaya, Nirmal) or ADMIN submit_for_next_stage
--   on work they do not personally hold.
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- 0015 introduced public.can_change_status() and wired it into
-- enforce_status_change_permission() so that approve_work_item and
-- request_changes already let a controller act on work that is neither
-- theirs nor at their gate ("move work that is neither theirs nor at their
-- gate" is explicitly one of the things 0015 reserves to Vijaya/Nirmal).
--
-- submit_for_next_stage was never given the same exception: it has always had
-- its own, separate ownership guard ("You do not hold this work item",
-- ERRCODE 42501) that runs before the trigger ever sees the UPDATE, and that
-- guard has no can_change_status() branch. So even a controller calling
-- submit_for_next_stage on a card they don't hold was — and, absent this
-- migration, still is — rejected by that guard alone, regardless of role.
--
-- This is the server-side half of the Board fix (see
-- src/lib/workflow/board.ts's canOverride): the Board now offers the drag to
-- a controller for cards they don't hold, but that drag calls this exact
-- function for the "forward, no approval gate" case, so without this change
-- the drag would succeed in the UI and then fail with "You do not hold this
-- work item" on drop.
--
-- Only the guard clause changes; everything else is byte-for-byte the
-- function from 0007. p_task then legitimately stays NULL for an override
-- call — already handled throughout (see "IF v_task.id IS NOT NULL" below),
-- since PARALLEL/SEQUENTIAL work and the closing of "this person's task" were
-- always optional depending on whether the actor held a task.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.submit_for_next_stage(
  p_work_item_id UUID,
  p_notes        TEXT DEFAULT NULL,
  p_file_ids     UUID[] DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor          UUID := auth.uid();
  v_work           public.work_items%ROWTYPE;
  v_stage          public.workflow_stages%ROWTYPE;
  v_multi_mode     TEXT;
  v_task           public.tasks%ROWTYPE;
  v_trigger        TEXT;
  v_next_stage_id  UUID;
  v_next_stage     public.workflow_stages%ROWTYPE;
  v_transition_found BOOLEAN;
  v_next_assignee  UUID;
  v_next_deadline  DATE;
  v_submission_id  UUID;
  v_submission_no  INT;
  v_new_task_id    UUID;
  v_pending_total  INT;
  v_missing_files  INT;
  v_next_status    TEXT;
  v_action_type    TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  -- Lock the row for the duration of the transaction so two people clicking
  -- Submit at the same moment cannot both advance the stage.
  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_work.status IN ('COMPLETED','CANCELLED','REJECTED') THEN
    RAISE EXCEPTION 'Work item is % and cannot be submitted', v_work.status
      USING ERRCODE = '22023';
  END IF;

  IF v_work.status = 'ON_HOLD' THEN
    RAISE EXCEPTION 'Work item is on hold. Resume it before submitting.'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item has no current stage' USING ERRCODE = '22023';
  END IF;

  SELECT multi_owner_behavior INTO v_multi_mode
  FROM public.workflow_templates WHERE id = v_work.workflow_id;

  -- ---- 1. VALIDATE -------------------------------------------------------
  -- The caller must actually hold this work: an open task, or be the
  -- assignee/owner. A STATUS_CONTROLLER / ADMIN (public.can_change_status())
  -- is exempt, mirroring the exemption enforce_status_change_permission()
  -- already gives approve_work_item and request_changes (0015) — moving work
  -- that is neither theirs nor at their gate is exactly what that role is for.
  SELECT * INTO v_task FROM public.tasks
  WHERE work_item_id = p_work_item_id
    AND assignee_id = v_actor
    AND closed_at IS NULL
  LIMIT 1;

  IF NOT FOUND
     AND v_work.current_assignee_id IS DISTINCT FROM v_actor
     AND v_work.owner_id IS DISTINCT FROM v_actor
     AND NOT EXISTS (
       SELECT 1 FROM public.work_item_owners
       WHERE work_item_id = p_work_item_id AND user_id = v_actor
     )
     AND NOT public.can_change_status()
  THEN
    RAISE EXCEPTION 'You do not hold this work item' USING ERRCODE = '42501';
  END IF;

  IF v_stage.requires_attachment THEN
    SELECT COUNT(*) INTO v_missing_files
    FROM public.files
    WHERE work_item_id = p_work_item_id
      AND deleted_at IS NULL
      AND (stage_id = v_stage.id OR stage_id IS NULL);

    IF v_missing_files = 0 THEN
      RAISE EXCEPTION 'Stage "%" requires at least one attachment', v_stage.name
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- ---- 2. RECORD THE SUBMISSION (append-only) ----------------------------
  v_submission_no := COALESCE(v_work.submission_count, 0) + 1;

  INSERT INTO public.submissions (
    work_item_id, task_id, stage_id, submission_number, submitted_by, notes, snapshot
  ) VALUES (
    p_work_item_id, v_task.id, v_stage.id, v_submission_no, v_actor, p_notes,
    jsonb_build_object(
      'status', v_work.status,
      'stage_id', v_work.current_stage_id,
      'stage_name', v_stage.name,
      'assignee_id', v_work.current_assignee_id,
      'priority', v_work.priority,
      'stage_deadline', v_work.stage_deadline
    )
  ) RETURNING id INTO v_submission_id;

  IF p_file_ids IS NOT NULL THEN
    UPDATE public.files
    SET submission_id = v_submission_id
    WHERE id = ANY(p_file_ids) AND work_item_id = p_work_item_id;
  END IF;

  -- Close this person's task
  IF v_task.id IS NOT NULL THEN
    UPDATE public.tasks
    SET status = 'SUBMITTED', closed_at = NOW(), closed_reason = 'Submitted for next stage'
    WHERE id = v_task.id;
  END IF;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, detail)
  VALUES (p_work_item_id, v_task.id, v_actor, 'SUBMITTED',
          jsonb_build_object('stage', v_stage.name, 'submission_number', v_submission_no,
                             'notes', p_notes));

  -- ---- 3. MULTI-OWNER GATE ----------------------------------------------
  -- PARALLEL work only advances once every collaborator has submitted.
  IF v_multi_mode = 'PARALLEL' THEN
    UPDATE public.work_item_owners
    SET submission_status = 'SUBMITTED', submitted_at = NOW()
    WHERE work_item_id = p_work_item_id AND user_id = v_actor;

    SELECT COUNT(*) INTO v_pending_total
    FROM public.work_item_owners
    WHERE work_item_id = p_work_item_id AND submission_status = 'PENDING';

    IF v_pending_total > 0 THEN
      UPDATE public.work_items
      SET status = 'SUBMITTED',
          substatus = format('Waiting on %s more collaborator(s)', v_pending_total),
          submission_count = v_submission_no
      WHERE id = p_work_item_id;

      -- Nudge whoever is still holding it
      INSERT INTO public.notifications (recipient_id, work_item_id, type, subject, body, action_url)
      SELECT o.user_id, p_work_item_id, 'ASSIGNMENT',
             format('Still awaiting your submission: %s', v_work.name),
             format('%s has submitted. This work advances once all collaborators submit.',
                    (SELECT full_name FROM public.users WHERE id = v_actor)),
             '/work/' || p_work_item_id
      FROM public.work_item_owners o
      WHERE o.work_item_id = p_work_item_id AND o.submission_status = 'PENDING';

      RETURN jsonb_build_object(
        'advanced', FALSE,
        'reason', 'awaiting_collaborators',
        'pending_collaborators', v_pending_total,
        'submission_id', v_submission_id
      );
    END IF;
  END IF;

  -- SEQUENTIAL hands to the next collaborator in order before leaving the stage.
  IF v_multi_mode = 'SEQUENTIAL' THEN
    UPDATE public.work_item_owners
    SET submission_status = 'SUBMITTED', submitted_at = NOW()
    WHERE work_item_id = p_work_item_id AND user_id = v_actor;

    SELECT o.user_id INTO v_next_assignee
    FROM public.work_item_owners o
    WHERE o.work_item_id = p_work_item_id
      AND o.submission_status = 'PENDING'
    ORDER BY o.sequence_order NULLS LAST, o.assigned_at
    LIMIT 1;

    IF v_next_assignee IS NOT NULL THEN
      v_next_deadline := public.compute_stage_deadline(v_stage.id, v_work.priority);

      INSERT INTO public.tasks (
        work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
        action_type, priority, due_date
      ) VALUES (
        p_work_item_id, v_stage.id, v_next_assignee, v_actor,
        format('%s — %s', v_work.name, v_stage.name),
        p_notes, 'COMPLETE_STAGE', v_work.priority, v_next_deadline
      ) RETURNING id INTO v_new_task_id;

      UPDATE public.work_items
      SET current_assignee_id = v_next_assignee,
          pending_with_id     = v_next_assignee,
          pending_with_label  = NULL,
          status              = 'IN_PROGRESS',
          stage_deadline      = v_next_deadline,
          submission_count    = v_submission_no,
          handoff_at          = NOW(),
          handoff_by          = v_actor
      WHERE id = p_work_item_id;

      INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value)
      VALUES (p_work_item_id, v_new_task_id, v_actor, 'ASSIGNED',
              (SELECT full_name FROM public.users WHERE id = v_actor),
              (SELECT full_name FROM public.users WHERE id = v_next_assignee));

      INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
      VALUES (v_next_assignee, p_work_item_id, v_new_task_id, 'ASSIGNMENT',
              format('Your turn: %s', v_work.name),
              format('Handed to you at stage %s.', v_stage.name),
              '/work/' || p_work_item_id);

      RETURN jsonb_build_object(
        'advanced', FALSE,
        'reason', 'sequential_handoff',
        'next_assignee_id', v_next_assignee,
        'task_id', v_new_task_id
      );
    END IF;
  END IF;

  -- ---- 4. MOVE STAGE -----------------------------------------------------
  v_trigger := public.resolve_submit_trigger(v_stage.id, v_work.po_required);

  SELECT t.to_stage_id, TRUE INTO v_next_stage_id, v_transition_found
  FROM public.workflow_transitions t
  WHERE t.from_stage_id = v_stage.id
    AND t.trigger_condition = v_trigger
    AND t.is_active
  LIMIT 1;

  IF NOT COALESCE(v_transition_found, FALSE) THEN
    RAISE EXCEPTION 'No % transition configured out of stage "%"', v_trigger, v_stage.name
      USING ERRCODE = '22023',
            HINT = 'Add a workflow_transitions row for this stage.';
  END IF;

  -- End of workflow
  IF v_next_stage_id IS NULL THEN
    UPDATE public.work_items
    SET status = 'COMPLETED',
        previous_stage_id = v_stage.id,
        current_stage_id  = NULL,
        current_assignee_id = NULL,
        pending_with_id   = NULL,
        pending_with_label= NULL,
        stage_deadline    = NULL,
        submission_count  = v_submission_no,
        completed_at      = NOW(),
        handoff_at        = NOW(),
        handoff_by        = v_actor
    WHERE id = p_work_item_id;

    INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value)
    VALUES (p_work_item_id, v_actor, 'COMPLETED', v_stage.name, NULL);

    RETURN jsonb_build_object('advanced', TRUE, 'completed', TRUE,
                              'submission_id', v_submission_id);
  END IF;

  SELECT * INTO v_next_stage FROM public.workflow_stages WHERE id = v_next_stage_id;

  -- ---- 5. IDENTIFY NEXT ASSIGNEE ----------------------------------------
  v_next_assignee := public.resolve_next_assignee(p_work_item_id, v_next_stage_id);
  v_next_deadline := public.compute_stage_deadline(v_next_stage_id, v_work.priority);

  v_action_type := CASE
    WHEN v_next_stage.requires_approval THEN 'APPROVE'
    ELSE 'COMPLETE_STAGE'
  END;

  -- A workflow can end two ways: a transition pointing at nothing (handled
  -- above), or landing on a stage flagged is_terminal. The 11-stage flow uses
  -- the second form because "Completed" is a real stage users need to see in
  -- the progress tracker -- without this it would sit there as IN_PROGRESS.
  v_next_status := CASE
    WHEN v_next_stage.is_terminal       THEN 'COMPLETED'
    WHEN v_next_stage.requires_approval THEN 'PENDING'
    WHEN v_next_assignee IS NULL        THEN 'PENDING'
    ELSE 'IN_PROGRESS'
  END;

  -- ---- 6. CREATE NEXT TASK ----------------------------------------------
  -- No task on a terminal stage: there is nothing left for anyone to do.
  IF v_next_assignee IS NOT NULL AND NOT v_next_stage.is_terminal THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id, v_next_stage_id, v_next_assignee, v_actor,
      format('%s — %s', v_work.name, v_next_stage.name),
      p_notes, v_action_type, v_work.priority, v_next_deadline
    ) RETURNING id INTO v_new_task_id;
  END IF;

  -- Reset collaborator submission flags for the new stage
  UPDATE public.work_item_owners
  SET submission_status = 'PENDING', submitted_at = NULL
  WHERE work_item_id = p_work_item_id;

  UPDATE public.work_items
  SET previous_stage_id  = v_stage.id,
      current_stage_id   = v_next_stage_id,
      -- Finished work is pending with nobody. Leaving an assignee on a
      -- terminal stage would keep it sitting in that person's My Work queue
      -- forever.
      current_assignee_id= CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_assignee END,
      pending_with_id    = CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_assignee END,
      pending_with_label = CASE
                             WHEN v_next_stage.is_terminal THEN NULL
                             WHEN v_next_assignee IS NULL   THEN 'unassigned'
                             ELSE NULL END,
      status             = v_next_status,
      substatus          = NULL,
      approval_required  = v_next_stage.requires_approval,
      approval_status    = CASE WHEN v_next_stage.requires_approval
                                THEN 'PENDING' ELSE approval_status END,
      stage_deadline     = CASE WHEN v_next_stage.is_terminal THEN NULL ELSE v_next_deadline END,
      submission_count   = v_submission_no,
      completed_at       = CASE WHEN v_next_stage.is_terminal THEN NOW() ELSE completed_at END,
      handoff_at         = NOW(),
      handoff_by         = v_actor
  WHERE id = p_work_item_id;

  -- ---- 7. ACTIVITY LOG ---------------------------------------------------
  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_new_task_id, v_actor, 'STAGE_CHANGED',
          v_stage.name, v_next_stage.name,
          jsonb_build_object('trigger', v_trigger, 'submission_id', v_submission_id));

  IF v_next_assignee IS NOT NULL THEN
    INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, to_value)
    VALUES (p_work_item_id, v_new_task_id, v_actor, 'ASSIGNED',
            (SELECT full_name FROM public.users WHERE id = v_next_assignee));
  ELSE
    INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
    VALUES (p_work_item_id, v_actor, 'UNASSIGNED',
            jsonb_build_object('reason', 'no approval authority or owner configured',
                               'stage', v_next_stage.name));
  END IF;

  -- ---- 8. NOTIFY ---------------------------------------------------------
  IF v_next_assignee IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
    VALUES (
      v_next_assignee, p_work_item_id, v_new_task_id,
      CASE WHEN v_next_stage.requires_approval THEN 'APPROVAL_REQUIRED' ELSE 'ASSIGNMENT' END,
      format('%s: %s', CASE WHEN v_next_stage.requires_approval
                            THEN 'Approval needed' ELSE 'New work assigned' END, v_work.name),
      format('Stage: %s. %s',
             v_next_stage.name,
             COALESCE('Due ' || v_next_deadline::TEXT, 'No due date set')),
      '/work/' || p_work_item_id
    );
  END IF;

  RETURN jsonb_build_object(
    'advanced', TRUE,
    'completed', FALSE,
    'from_stage', v_stage.name,
    'to_stage', v_next_stage.name,
    'trigger', v_trigger,
    'next_assignee_id', v_next_assignee,
    'task_id', v_new_task_id,
    'stage_deadline', v_next_deadline,
    'submission_id', v_submission_id
  );
END;
$$;
