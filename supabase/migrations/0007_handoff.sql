-- ============================================================================
-- 0007_handoff.sql — Automatic handoff engine
-- ============================================================================
-- Why this lives in plpgsql and not in TypeScript:
--
-- One handoff writes to submissions, tasks (close + open), work_items,
-- work_item_owners, activity_log and notifications. If it half-applies, the
-- work item disappears from BOTH people's queues — the submitter has closed
-- their task and the next person never got one. The Supabase JS client cannot
-- open a transaction across statements, so the whole mutation is one function
-- and therefore one transaction: it either all lands or none of it does.
--
-- SECURITY INVOKER (the default) is deliberate: the function runs as the
-- caller, so RLS still applies and nobody can hand off work they cannot see.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Deadline for a stage, as configuration.
-- Returns NULL when no SLA is configured — the caller then leaves the deadline
-- empty rather than inventing one.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_stage_deadline(
  p_stage_id UUID,
  p_priority TEXT
) RETURNS DATE LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_days INT;
BEGIN
  SELECT sla_days INTO v_days
  FROM public.stage_sla_config
  WHERE stage_id = p_stage_id AND priority = p_priority;

  IF v_days IS NULL THEN
    SELECT sla_days INTO v_days
    FROM public.workflow_stages
    WHERE id = p_stage_id;
  END IF;

  IF v_days IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN CURRENT_DATE + v_days;
END;
$$;

-- ----------------------------------------------------------------------------
-- Who should hold a stage next?
--
-- Approval stages resolve through approval_authorities (category + amount band
-- + priority). Everything else resolves to a collaborator holding the stage's
-- expected role, falling back to the work item's owner.
--
-- Returns NULL when nothing matches. That is a real answer, not a failure:
-- the caller parks the item as unassigned so it surfaces on the Control Tower
-- instead of being silently handed to an arbitrary person.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_next_assignee(
  p_work_item_id UUID,
  p_stage_id     UUID
) RETURNS UUID LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_requires_approval BOOLEAN;
  v_expected_role_id  UUID;
  v_approval_category TEXT;
  v_job_category      TEXT;
  v_priority          TEXT;
  v_amount            NUMERIC;
  v_owner_id          UUID;
  v_assignee          UUID;
BEGIN
  SELECT s.requires_approval, s.expected_role_id, s.approval_category
    INTO v_requires_approval, v_expected_role_id, v_approval_category
  FROM public.workflow_stages s WHERE s.id = p_stage_id;

  SELECT j.category, w.priority, w.estimated_amount, w.owner_id
    INTO v_job_category, v_priority, v_amount, v_owner_id
  FROM public.work_items w
  JOIN public.jobs j ON j.id = w.job_id
  WHERE w.id = p_work_item_id;

  IF v_requires_approval THEN
    SELECT aa.approver_id INTO v_assignee
    FROM public.approval_authorities aa
    WHERE aa.is_active
      AND aa.work_category = COALESCE(v_approval_category, v_job_category)
      AND COALESCE(v_amount, 0) >= aa.amount_min
      AND (aa.amount_max IS NULL OR COALESCE(v_amount, 0) <= aa.amount_max)
      AND (aa.applies_to_priority IS NULL OR aa.applies_to_priority = v_priority)
    ORDER BY aa.approval_level, aa.created_at
    LIMIT 1;

    RETURN v_assignee;  -- may be NULL: no authority configured for this category
  END IF;

  IF v_expected_role_id IS NOT NULL THEN
    SELECT o.user_id INTO v_assignee
    FROM public.work_item_owners o
    JOIN public.user_roles ur ON ur.user_id = o.user_id
    WHERE o.work_item_id = p_work_item_id
      AND ur.role_id = v_expected_role_id
    ORDER BY CASE o.owner_role WHEN 'PRIMARY' THEN 0 ELSE 1 END, o.assigned_at
    LIMIT 1;

    IF v_assignee IS NOT NULL THEN
      RETURN v_assignee;
    END IF;
  END IF;

  RETURN v_owner_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Which edge do we take out of this stage on a submit?
--
-- If the stage defines PO branching edges, the po_required flag picks between
-- them. Otherwise the plain SUBMISSION edge is taken. No stage NAME is ever
-- tested, so renaming or reordering stages cannot break routing.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_submit_trigger(
  p_stage_id    UUID,
  p_po_required BOOLEAN
) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_has_po_edges BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.workflow_transitions
    WHERE from_stage_id = p_stage_id
      AND is_active
      AND trigger_condition IN ('PO_REQUIRED','NO_PO')
  ) INTO v_has_po_edges;

  IF v_has_po_edges THEN
    RETURN CASE WHEN p_po_required THEN 'PO_REQUIRED' ELSE 'NO_PO' END;
  END IF;

  RETURN 'SUBMISSION';
END;
$$;

-- ============================================================================
-- submit_for_next_stage
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
  -- assignee/owner. Anything else is rejected even if RLS let them read it.
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

-- ============================================================================
-- request_changes — the Return Rule
-- ============================================================================
CREATE OR REPLACE FUNCTION public.request_changes(
  p_work_item_id UUID,
  p_reason       TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor         UUID := auth.uid();
  v_work          public.work_items%ROWTYPE;
  v_stage         public.workflow_stages%ROWTYPE;
  v_target_id     UUID;
  v_target        public.workflow_stages%ROWTYPE;
  v_found         BOOLEAN;
  v_prev_owner    UUID;
  v_deadline      DATE;
  v_task_id       UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required when requesting changes'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;

  SELECT t.to_stage_id, TRUE INTO v_target_id, v_found
  FROM public.workflow_transitions t
  WHERE t.from_stage_id = v_work.current_stage_id
    AND t.trigger_condition = 'CHANGES_REQUIRED'
    AND t.is_active
  LIMIT 1;

  -- Fall back to the stage the item actually came from when the workflow
  -- doesn't define an explicit rollback edge.
  IF NOT COALESCE(v_found, FALSE) THEN
    v_target_id := v_work.previous_stage_id;
  END IF;

  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'Nowhere to send this back to' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_target FROM public.workflow_stages WHERE id = v_target_id;

  -- Send it back to whoever submitted it last, not to a generic role.
  SELECT submitted_by INTO v_prev_owner
  FROM public.submissions
  WHERE work_item_id = p_work_item_id
  ORDER BY submission_number DESC
  LIMIT 1;

  v_prev_owner := COALESCE(v_prev_owner, v_work.owner_id);
  v_deadline   := public.compute_stage_deadline(v_target_id, v_work.priority);

  INSERT INTO public.approvals (work_item_id, stage_id, approver_id, outcome, reason)
  VALUES (p_work_item_id, v_work.current_stage_id, v_actor, 'CHANGES_REQUIRED', p_reason);

  INSERT INTO public.comments (work_item_id, author_id, body, comment_type)
  VALUES (p_work_item_id, v_actor, p_reason, 'CHANGE_REQUEST');

  -- Close any open task at the stage we're leaving
  UPDATE public.tasks
  SET status = 'CANCELLED', closed_at = NOW(), closed_reason = 'Changes requested'
  WHERE work_item_id = p_work_item_id AND closed_at IS NULL;

  IF v_prev_owner IS NOT NULL THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, assigned_by, title, instructions,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id, v_target_id, v_prev_owner, v_actor,
      format('Revise: %s', v_work.name), p_reason, 'REVISE',
      v_work.priority, v_deadline
    ) RETURNING id INTO v_task_id;
  END IF;

  UPDATE public.work_items
  SET previous_stage_id   = v_work.current_stage_id,
      current_stage_id    = v_target_id,
      current_assignee_id = v_prev_owner,
      pending_with_id     = v_prev_owner,
      pending_with_label  = CASE WHEN v_prev_owner IS NULL THEN 'unassigned' ELSE NULL END,
      status              = 'CHANGES_REQUIRED',
      approval_status     = 'CHANGES_REQUIRED',
      stage_deadline      = v_deadline,
      handoff_at          = NOW(),
      handoff_by          = v_actor
  WHERE id = p_work_item_id;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'CHANGES_REQUESTED',
          v_stage.name, v_target.name, jsonb_build_object('reason', p_reason));

  IF v_prev_owner IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
    VALUES (v_prev_owner, p_work_item_id, v_task_id, 'CHANGES_REQUIRED',
            format('Changes requested: %s', v_work.name), p_reason,
            '/work/' || p_work_item_id);
  END IF;

  RETURN jsonb_build_object(
    'returned_to_stage', v_target.name,
    'assigned_to', v_prev_owner,
    'task_id', v_task_id
  );
END;
$$;

-- ============================================================================
-- put_on_hold / resume
-- ============================================================================
CREATE OR REPLACE FUNCTION public.put_on_hold(
  p_work_item_id UUID,
  p_reason       TEXT,
  p_blocker_type TEXT DEFAULT 'other'
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_work  public.work_items%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required to put work on hold' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  -- The stage is deliberately left untouched so the item resumes where it stopped.
  UPDATE public.work_items
  SET status       = 'ON_HOLD',
      blocker_type = p_blocker_type,
      blocker_note = p_reason
  WHERE id = p_work_item_id;

  UPDATE public.tasks
  SET status = 'ON_HOLD'
  WHERE work_item_id = p_work_item_id AND closed_at IS NULL;

  INSERT INTO public.comments (work_item_id, author_id, body, comment_type)
  VALUES (p_work_item_id, v_actor, p_reason, 'HOLD_REASON');

  INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_actor, 'PUT_ON_HOLD', v_work.status, 'ON_HOLD',
          jsonb_build_object('reason', p_reason, 'blocker_type', p_blocker_type));

  RETURN jsonb_build_object('status', 'ON_HOLD', 'reason', p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.resume_work(
  p_work_item_id UUID
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_work  public.work_items%ROWTYPE;
  v_status TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  v_status := CASE WHEN v_work.current_assignee_id IS NULL THEN 'PENDING' ELSE 'IN_PROGRESS' END;

  UPDATE public.work_items
  SET status = v_status, blocker_type = NULL, blocker_note = NULL
  WHERE id = p_work_item_id;

  UPDATE public.tasks
  SET status = 'PENDING'
  WHERE work_item_id = p_work_item_id AND closed_at IS NULL AND status = 'ON_HOLD';

  INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value)
  VALUES (p_work_item_id, v_actor, 'RESUMED', 'ON_HOLD', v_status);

  RETURN jsonb_build_object('status', v_status);
END;
$$;

-- ============================================================================
-- approve — the forward half of an approval decision
-- ============================================================================
CREATE OR REPLACE FUNCTION public.approve_work_item(
  p_work_item_id UUID,
  p_notes        TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_actor        UUID := auth.uid();
  v_work         public.work_items%ROWTYPE;
  v_stage        public.workflow_stages%ROWTYPE;
  v_trigger      TEXT;
  v_next_id      UUID;
  v_found        BOOLEAN;
  v_next         public.workflow_stages%ROWTYPE;
  v_assignee     UUID;
  v_deadline     DATE;
  v_task_id      UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_work FROM public.work_items
  WHERE id = p_work_item_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_stage FROM public.workflow_stages WHERE id = v_work.current_stage_id;

  INSERT INTO public.approvals (work_item_id, stage_id, approver_id, outcome, reason)
  VALUES (p_work_item_id, v_work.current_stage_id, v_actor, 'APPROVED', p_notes);

  -- An approval stage may still branch on PO.
  v_trigger := public.resolve_submit_trigger(v_work.current_stage_id, v_work.po_required);
  IF v_trigger = 'SUBMISSION' THEN
    v_trigger := 'APPROVED';
  END IF;

  SELECT t.to_stage_id, TRUE INTO v_next_id, v_found
  FROM public.workflow_transitions t
  WHERE t.from_stage_id = v_work.current_stage_id
    AND t.trigger_condition = v_trigger
    AND t.is_active
  LIMIT 1;

  IF NOT COALESCE(v_found, FALSE) THEN
    RAISE EXCEPTION 'No % transition configured out of stage "%"', v_trigger, v_stage.name
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.tasks
  SET status = 'COMPLETED', closed_at = NOW(), closed_reason = 'Approved'
  WHERE work_item_id = p_work_item_id AND assignee_id = v_actor AND closed_at IS NULL;

  IF v_next_id IS NULL THEN
    UPDATE public.work_items
    SET status = 'COMPLETED', approval_status = 'APPROVED',
        previous_stage_id = v_work.current_stage_id,
        current_stage_id = NULL, current_assignee_id = NULL,
        pending_with_id = NULL, pending_with_label = NULL,
        completed_at = NOW()
    WHERE id = p_work_item_id;

    INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value)
    VALUES (p_work_item_id, v_actor, 'APPROVED_AND_COMPLETED', v_stage.name);

    RETURN jsonb_build_object('approved', TRUE, 'completed', TRUE);
  END IF;

  SELECT * INTO v_next FROM public.workflow_stages WHERE id = v_next_id;
  v_assignee := public.resolve_next_assignee(p_work_item_id, v_next_id);
  v_deadline := public.compute_stage_deadline(v_next_id, v_work.priority);

  IF v_assignee IS NOT NULL THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, assigned_by, title,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id, v_next_id, v_assignee, v_actor,
      format('%s — %s', v_work.name, v_next.name),
      CASE WHEN v_next.requires_approval THEN 'APPROVE' ELSE 'COMPLETE_STAGE' END,
      v_work.priority, v_deadline
    ) RETURNING id INTO v_task_id;
  END IF;

  UPDATE public.work_items
  SET previous_stage_id   = v_work.current_stage_id,
      current_stage_id    = v_next_id,
      current_assignee_id = v_assignee,
      pending_with_id     = v_assignee,
      pending_with_label  = CASE WHEN v_assignee IS NULL THEN 'unassigned' ELSE NULL END,
      status              = CASE WHEN v_assignee IS NULL THEN 'PENDING' ELSE 'IN_PROGRESS' END,
      approval_status     = CASE WHEN v_next.requires_approval THEN 'PENDING' ELSE 'APPROVED' END,
      approval_required   = v_next.requires_approval,
      stage_deadline      = v_deadline,
      handoff_at          = NOW(),
      handoff_by          = v_actor
  WHERE id = p_work_item_id;

  INSERT INTO public.activity_log (work_item_id, task_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, v_task_id, v_actor, 'APPROVED', v_stage.name, v_next.name,
          jsonb_build_object('trigger', v_trigger, 'notes', p_notes));

  IF v_assignee IS NOT NULL THEN
    INSERT INTO public.notifications (recipient_id, work_item_id, task_id, type, subject, body, action_url)
    VALUES (v_assignee, p_work_item_id, v_task_id, 'ASSIGNMENT',
            format('Approved — now with you: %s', v_work.name),
            format('Stage: %s', v_next.name), '/work/' || p_work_item_id);
  END IF;

  RETURN jsonb_build_object('approved', TRUE, 'completed', FALSE,
                            'to_stage', v_next.name, 'next_assignee_id', v_assignee,
                            'task_id', v_task_id);
END;
$$;
