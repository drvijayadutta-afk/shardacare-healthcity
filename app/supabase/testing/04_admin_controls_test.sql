-- ============================================================================
-- LOCAL TEST ONLY — add_task_to_work_item, reassign_work_item and remove_task
-- (0013), and that the role gate on each matches its RLS policy exactly.
--
-- Originally WORKFLOW_MANAGER could add/reassign but not delete; 0026
-- narrowed all three to STATUS_CONTROLLER (Nirmal, Vijaya) plus ADMIN, so
-- v_controller below now holds STATUS_CONTROLLER, not WORKFLOW_MANAGER —
-- see 10_task_control_restricted_test.sql for the fuller before/after
-- coverage (a COORDINATOR refused, a direct INSERT bypass refused, ADMIN
-- retained). A plain CREATOR still may do none of the three.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_admin UUID; v_controller UUID; v_plain UUID; v_target UUID; v_target2 UUID;
  v_wf UUID; v_job UUID; v_work UUID; v_task UUID; v_task2 UUID; v_res JSONB;
  v_failed BOOLEAN;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('admin-t@t.test','{"full_name":"AdminT"}')     RETURNING id INTO v_admin;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('controller-t@t.test','{"full_name":"ControllerT"}') RETURNING id INTO v_controller;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('plain-t@t.test','{"full_name":"PlainT"}')     RETURNING id INTO v_plain;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('target-t@t.test','{"full_name":"TargetT"}')   RETURNING id INTO v_target;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('target2-t@t.test','{"full_name":"Target2T"}') RETURNING id INTO v_target2;

  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_admin, id FROM public.roles WHERE name='ADMIN';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_controller, id FROM public.roles WHERE name='STATUS_CONTROLLER';
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

  -- ---- A plain CREATOR may not add a task -------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_plain::TEXT, TRUE);
  v_failed := FALSE;
  BEGIN
    PERFORM public.add_task_to_work_item(v_work, v_target, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed := TRUE;
    IF SQLSTATE <> '42501' THEN RAISE EXCEPTION 'FAIL: wrong error for unprivileged add: % %', SQLSTATE, SQLERRM; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a CREATOR was allowed to add a task'; END IF;
  RAISE NOTICE 'PASS  a plain user cannot add a task';

  -- ---- A STATUS_CONTROLLER adding a task to an unassigned item becomes ---
  -- the official handoff, same as reassign would on an empty item.
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  v_res := public.add_task_to_work_item(v_work, v_target, 'first task');

  IF (SELECT current_assignee_id FROM public.work_items WHERE id=v_work) <> v_target THEN
    RAISE EXCEPTION 'FAIL: add_task on an unassigned item did not become the holder';
  END IF;
  SELECT id INTO v_task FROM public.tasks
  WHERE work_item_id=v_work AND assignee_id=v_target AND closed_at IS NULL;
  IF v_task IS NULL THEN RAISE EXCEPTION 'FAIL: add_task created no task'; END IF;
  RAISE NOTICE 'PASS  adding a task to an unassigned item makes it the official handoff';

  -- ---- Adding a second task does not disturb the first --------------------
  v_res := public.add_task_to_work_item(v_work, v_target2, 'helping out');

  IF (SELECT current_assignee_id FROM public.work_items WHERE id=v_work) <> v_target THEN
    RAISE EXCEPTION 'FAIL: adding a second (helper) task changed the existing holder';
  END IF;
  SELECT id INTO v_task2 FROM public.tasks
  WHERE work_item_id=v_work AND assignee_id=v_target2 AND closed_at IS NULL;
  IF v_task2 IS NULL THEN RAISE EXCEPTION 'FAIL: helper task was not created'; END IF;
  IF (SELECT id FROM public.tasks WHERE id=v_task) IS NULL THEN
    RAISE EXCEPTION 'FAIL: the original holder''s task was closed by adding a helper';
  END IF;
  RAISE NOTICE 'PASS  a second task can be added without disturbing the current holder';

  -- ---- Cannot add a duplicate open task for the same person/stage -------
  v_failed := FALSE;
  BEGIN
    PERFORM public.add_task_to_work_item(v_work, v_target, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed := TRUE;
    IF SQLSTATE <> '22023' THEN RAISE EXCEPTION 'FAIL: wrong error for duplicate task: % %', SQLSTATE, SQLERRM; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a duplicate open task was allowed'; END IF;
  RAISE NOTICE 'PASS  the same person cannot get a second open task at the same stage';

  -- Clean up the helper task so the reassign test below starts from the
  -- single-holder state it expects.
  PERFORM set_config('request.jwt.claim.sub', v_admin::TEXT, TRUE);
  PERFORM public.remove_task(v_task2, 'test cleanup');

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

  -- ---- A STATUS_CONTROLLER may reassign, moving it off v_target onto v_target2
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  v_res := public.reassign_work_item(v_work, v_target2, 'test note');

  IF (SELECT current_assignee_id FROM public.work_items WHERE id=v_work) <> v_target2 THEN
    RAISE EXCEPTION 'FAIL: reassign did not set current_assignee_id';
  END IF;
  IF (SELECT pending_with_id FROM public.work_items WHERE id=v_work) <> v_target2 THEN
    RAISE EXCEPTION 'FAIL: reassign did not set pending_with_id';
  END IF;
  -- v_target's original task must be closed, not left open alongside the new one.
  IF EXISTS (
    SELECT 1 FROM public.tasks
    WHERE work_item_id=v_work AND assignee_id=v_target AND closed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: reassign left the previous holder''s task open';
  END IF;

  SELECT id INTO v_task FROM public.tasks
  WHERE work_item_id=v_work AND assignee_id=v_target2 AND closed_at IS NULL;
  IF v_task IS NULL THEN RAISE EXCEPTION 'FAIL: no open task created for the new assignee'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.activity_log
    WHERE work_item_id=v_work AND action='REASSIGNED' AND from_value='TargetT'
  ) THEN
    RAISE EXCEPTION 'FAIL: no REASSIGNED activity log entry (or wrong from_value)';
  END IF;
  RAISE NOTICE 'PASS  a status controller can reassign work off its current holder';

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
  RAISE NOTICE 'PASS  a plain user cannot delete a task';

  -- ---- A STATUS_CONTROLLER may ALSO delete a task (0026 unified this with
  -- add/reassign, replacing the old ADMIN-only rule) -- proven on a
  -- throwaway task so v_task is left alone for the ADMIN test below.
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  v_res := public.add_task_to_work_item(v_work, v_target, 'throwaway for delete test');
  DECLARE v_throwaway UUID;
  BEGIN
    SELECT id INTO v_throwaway FROM public.tasks
    WHERE work_item_id=v_work AND assignee_id=v_target AND closed_at IS NULL;
    v_res := public.remove_task(v_throwaway, 'controller cleanup');
    IF EXISTS (SELECT 1 FROM public.tasks WHERE id=v_throwaway) THEN
      RAISE EXCEPTION 'FAIL: a STATUS_CONTROLLER''s delete did not remove the task';
    END IF;
  END;
  RAISE NOTICE 'PASS  a status controller can delete a task (not just ADMIN)';

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
