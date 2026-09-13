-- ============================================================================
-- LOCAL TEST ONLY — reassign_work_item and remove_task (0013), and that the
-- role gate on each matches its RLS policy exactly: WORKFLOW_MANAGER may
-- reassign but not delete a task; a plain CREATOR may do neither.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_admin UUID; v_manager UUID; v_plain UUID; v_target UUID;
  v_wf UUID; v_job UUID; v_work UUID; v_task UUID; v_res JSONB;
  v_failed BOOLEAN;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('admin-t@t.test','{"full_name":"AdminT"}')     RETURNING id INTO v_admin;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('manager-t@t.test','{"full_name":"ManagerT"}') RETURNING id INTO v_manager;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('plain-t@t.test','{"full_name":"PlainT"}')     RETURNING id INTO v_plain;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('target-t@t.test','{"full_name":"TargetT"}')   RETURNING id INTO v_target;

  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_admin, id FROM public.roles WHERE name='ADMIN';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_manager, id FROM public.roles WHERE name='WORKFLOW_MANAGER';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_plain, id FROM public.roles WHERE name='CREATOR';

  SELECT id INTO v_wf FROM public.workflow_templates WHERE name='Sharda Marketing Workflow';
  INSERT INTO public.jobs (name, category) VALUES ('Admin controls test', 'department')
  RETURNING id INTO v_job;

  -- Starts unassigned, exactly like the 20-odd imported items this doubles as
  -- a fix for: no current_assignee_id, no open task.
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name, status)
  SELECT v_job, v_wf, id, 'Unassigned test item', 'PENDING'
  FROM public.workflow_stages WHERE workflow_id=v_wf AND name='LEADERSHIP_BRIEF'
  RETURNING id INTO v_work;

  -- ---- A plain CREATOR may not reassign --------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_plain::TEXT, TRUE);
  v_failed := FALSE;
  BEGIN
    PERFORM public.reassign_work_item(v_work, v_target, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed := TRUE;
    IF SQLSTATE <> '42501' THEN RAISE EXCEPTION 'FAIL: wrong error for unprivileged reassign: % %', SQLSTATE, SQLERRM; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a CREATOR was allowed to reassign work'; END IF;
  RAISE NOTICE 'PASS  a plain user cannot reassign work';

  -- ---- A WORKFLOW_MANAGER may reassign, including an unassigned item ---
  PERFORM set_config('request.jwt.claim.sub', v_manager::TEXT, TRUE);
  v_res := public.reassign_work_item(v_work, v_target, 'test note');

  IF (SELECT current_assignee_id FROM public.work_items WHERE id=v_work) <> v_target THEN
    RAISE EXCEPTION 'FAIL: reassign did not set current_assignee_id';
  END IF;
  IF (SELECT pending_with_id FROM public.work_items WHERE id=v_work) <> v_target THEN
    RAISE EXCEPTION 'FAIL: reassign did not set pending_with_id';
  END IF;

  SELECT id INTO v_task FROM public.tasks
  WHERE work_item_id=v_work AND assignee_id=v_target AND closed_at IS NULL;
  IF v_task IS NULL THEN RAISE EXCEPTION 'FAIL: no open task created for the new assignee'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.activity_log
    WHERE work_item_id=v_work AND action='REASSIGNED' AND from_value='unassigned'
  ) THEN
    RAISE EXCEPTION 'FAIL: no REASSIGNED activity log entry (or wrong from_value)';
  END IF;
  RAISE NOTICE 'PASS  a workflow manager can reassign an unassigned item';

  -- ---- A plain CREATOR may not delete a task ---------------------------
  PERFORM set_config('request.jwt.claim.sub', v_plain::TEXT, TRUE);
  v_failed := FALSE;
  BEGIN
    PERFORM public.remove_task(v_task, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed := TRUE;
    IF SQLSTATE <> '42501' THEN RAISE EXCEPTION 'FAIL: wrong error for unprivileged delete: % %', SQLSTATE, SQLERRM; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a CREATOR was allowed to delete a task'; END IF;

  -- ---- A WORKFLOW_MANAGER (not ADMIN) may not delete a task either -----
  -- Deliberately narrower than reassign: matches tasks_delete RLS, which is
  -- ADMIN-only, unlike tasks_update which WORKFLOW_MANAGER also holds.
  PERFORM set_config('request.jwt.claim.sub', v_manager::TEXT, TRUE);
  v_failed := FALSE;
  BEGIN
    PERFORM public.remove_task(v_task, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed := TRUE;
    IF SQLSTATE <> '42501' THEN RAISE EXCEPTION 'FAIL: wrong error for manager delete: % %', SQLSTATE, SQLERRM; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a WORKFLOW_MANAGER (non-admin) was allowed to delete a task'; END IF;
  RAISE NOTICE 'PASS  only ADMIN can delete a task, not WORKFLOW_MANAGER or CREATOR';

  -- ---- ADMIN deletes the task; the item reverts to honestly unassigned -
  PERFORM set_config('request.jwt.claim.sub', v_admin::TEXT, TRUE);
  v_res := public.remove_task(v_task, 'test cleanup');

  IF EXISTS (SELECT 1 FROM public.tasks WHERE id=v_task) THEN
    RAISE EXCEPTION 'FAIL: task row still exists after remove_task';
  END IF;
  IF (SELECT current_assignee_id FROM public.work_items WHERE id=v_work) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: current_assignee_id not cleared after deleting the only open task';
  END IF;
  IF (SELECT pending_with_label FROM public.work_items WHERE id=v_work) <> 'unassigned' THEN
    RAISE EXCEPTION 'FAIL: pending_with_label not reset to unassigned';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.activity_log WHERE work_item_id=v_work AND action='TASK_REMOVED'
  ) THEN
    RAISE EXCEPTION 'FAIL: no TASK_REMOVED activity log entry';
  END IF;
  RAISE NOTICE 'PASS  ADMIN deleting the only open task reverts the item to unassigned';

  -- ---- Cannot reassign completed work -----------------------------------
  UPDATE public.work_items
  SET status='COMPLETED', current_stage_id=NULL, completed_at=NOW()
  WHERE id=v_work;

  v_failed := FALSE;
  BEGIN
    PERFORM public.reassign_work_item(v_work, v_target, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed := TRUE;
    IF SQLSTATE <> '22023' THEN RAISE EXCEPTION 'FAIL: wrong error reassigning completed work: % %', SQLSTATE, SQLERRM; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: completed work was reassigned'; END IF;
  RAISE NOTICE 'PASS  completed work cannot be reassigned';

  RAISE NOTICE 'ALL ADMIN CONTROLS TESTS PASSED';
END
$t$;
