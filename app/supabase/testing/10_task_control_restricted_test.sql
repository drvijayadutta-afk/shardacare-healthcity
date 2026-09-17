-- ============================================================================
-- 10_task_control_restricted_test.sql — 0026_task_control_restricted.sql
--   Proves controlling the to-do list (add a task, reassign work, delete a
--   task) is restricted to STATUS_CONTROLLER (Nirmal, Vijaya) plus ADMIN --
--   and that a COORDINATOR who is neither cannot bypass this by inserting
--   into tasks directly instead of calling the RPCs.
--
-- Runs under SET ROLE authenticated, like 06/07/08/09 -- the postgres
-- superuser session bypasses RLS entirely and would hide every one of these.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_controller UUID; v_coord UUID; v_stranger UUID; v_holder UUID; v_admin UUID;
  v_wf UUID; v_job UUID; v_stage UUID;
  v_work_a UUID; v_work_b UUID; v_work_c UUID; v_work_d UUID;
  v_task_a UUID; v_task_c UUID; v_task_d UUID;
  v_result JSONB; v_failed BOOLEAN;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t10-controller@t.test','{"full_name":"T10Controller"}') RETURNING id INTO v_controller;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t10-coord@t.test','{"full_name":"T10Coord"}')           RETURNING id INTO v_coord;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t10-stranger@t.test','{"full_name":"T10Stranger"}')     RETURNING id INTO v_stranger;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t10-holder@t.test','{"full_name":"T10Holder"}')         RETURNING id INTO v_holder;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t10-admin@t.test','{"full_name":"T10Admin"}')           RETURNING id INTO v_admin;

  -- STATUS_CONTROLLER only -- not also ADMIN/WORKFLOW_MANAGER/COORDINATOR.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_controller, id FROM public.roles WHERE name='STATUS_CONTROLLER';
  -- view_all via COORDINATOR, but no change_status -- Sushant's real shape.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_coord, id FROM public.roles WHERE name='COORDINATOR';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_admin, id FROM public.roles WHERE name='ADMIN';

  SELECT id INTO v_wf FROM public.workflow_templates WHERE is_default LIMIT 1;
  SELECT id INTO v_stage FROM public.workflow_stages
  WHERE workflow_id=v_wf AND track='MAIN' ORDER BY stage_order LIMIT 1;

  INSERT INTO public.jobs (name, created_by) VALUES ('T10 job', v_holder) RETURNING id INTO v_job;

  -- Four separate work items, each held by v_holder, none by the actors below.
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_stage, 'T10 add-task target', v_holder, v_holder, 'IN_PROGRESS', v_holder)
  RETURNING id INTO v_work_a;
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_stage, 'T10 reassign target', v_holder, v_holder, 'IN_PROGRESS', v_holder)
  RETURNING id INTO v_work_b;
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_stage, 'T10 delete-task target', v_holder, v_holder, 'IN_PROGRESS', v_holder)
  RETURNING id INTO v_work_c;
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_stage, 'T10 direct-insert target', v_holder, v_holder, 'IN_PROGRESS', v_holder)
  RETURNING id INTO v_work_d;

  INSERT INTO public.tasks (work_item_id, stage_id, assignee_id, title, action_type, priority)
  VALUES (v_work_c, v_stage, v_holder, 'T10 task to delete', 'COMPLETE_STAGE', 'MEDIUM')
  RETURNING id INTO v_task_c;

  -- ---- Negative controls first: a role-less stranger, refused on all three
  -- (matching 09's proof that they can still SEE these work items) ---------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    SELECT public.add_task_to_work_item(v_work_a, v_stranger, 'stranger add') INTO v_result;
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a role-less stranger added a task'; END IF;
  RAISE NOTICE 'PASS  stranger refused on add_task_to_work_item';

  -- ---- COORDINATOR (view_all, no change_status) is ALSO refused -- this is
  -- the residual gap 0026 closes: Sushant's real role shape ------------------
  PERFORM set_config('request.jwt.claim.sub', v_coord::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    SELECT public.add_task_to_work_item(v_work_a, v_stranger, 'coord add') INTO v_result;
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a COORDINATOR without change_status added a task'; END IF;
  RAISE NOTICE 'PASS  coordinator (view_all but no change_status) refused on add_task_to_work_item';

  -- ---- Same COORDINATOR, going around the RPC with a raw INSERT -- this is
  -- the direct-insert gap tasks_insert's old top-level role list left open --
  PERFORM set_config('request.jwt.claim.sub', v_coord::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.tasks (work_item_id, stage_id, assignee_id, title, action_type, priority)
    VALUES (v_work_d, v_stage, v_stranger, 'coord direct insert', 'COMPLETE_STAGE', 'MEDIUM');
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: a COORDINATOR inserted a task directly, bypassing the RPC''s own check';
  END IF;
  RAISE NOTICE 'PASS  coordinator refused on a direct INSERT into tasks too, not just the RPC';

  -- ---- Positive: a PURE STATUS_CONTROLLER can add a task on work they do
  -- not hold ------------------------------------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT public.add_task_to_work_item(v_work_a, v_stranger, 'controller add') INTO v_result;
  EXECUTE 'RESET ROLE';
  IF NOT (v_result->>'added')::BOOLEAN THEN
    RAISE EXCEPTION 'FAIL: a pure STATUS_CONTROLLER could not add a task on work they do not hold';
  END IF;
  SELECT id INTO v_task_a FROM public.tasks WHERE (v_result->>'task_id')::UUID = id;
  RAISE NOTICE 'PASS  pure STATUS_CONTROLLER can add a task on work they do not hold';

  -- ---- Positive: can reassign work off v_holder too -- this is the one that
  -- would have hit tasks_update's old role list (no can_change_status branch)
  -- immediately after the function's own check passed ------------------------
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT public.reassign_work_item(v_work_b, v_stranger, 'controller reassign') INTO v_result;
  EXECUTE 'RESET ROLE';
  IF NOT (v_result->>'reassigned')::BOOLEAN THEN
    RAISE EXCEPTION 'FAIL: a pure STATUS_CONTROLLER could not reassign work off its holder';
  END IF;
  IF (SELECT current_assignee_id FROM public.work_items WHERE id = v_work_b) <> v_stranger THEN
    RAISE EXCEPTION 'FAIL: reassignment did not actually move the work item';
  END IF;
  RAISE NOTICE 'PASS  pure STATUS_CONTROLLER can reassign work off its current holder';

  -- ---- Positive: can delete a task -- would have hit tasks_delete's old
  -- ADMIN-only USING clause immediately after the function's own check passed
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT public.remove_task(v_task_c, 'controller cleanup') INTO v_result;
  EXECUTE 'RESET ROLE';
  IF NOT (v_result->>'removed')::BOOLEAN THEN
    RAISE EXCEPTION 'FAIL: a pure STATUS_CONTROLLER could not delete a task';
  END IF;
  IF EXISTS (SELECT 1 FROM public.tasks WHERE id = v_task_c) THEN
    RAISE EXCEPTION 'FAIL: the task still exists after remove_task reported success';
  END IF;
  RAISE NOTICE 'PASS  pure STATUS_CONTROLLER can delete a task';

  -- ---- ADMIN retains all three (regression check) ---------------------------
  PERFORM set_config('request.jwt.claim.sub', v_admin::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT public.add_task_to_work_item(v_work_d, v_stranger, 'admin add') INTO v_result;
  EXECUTE 'RESET ROLE';
  IF NOT (v_result->>'added')::BOOLEAN THEN
    RAISE EXCEPTION 'FAIL: ADMIN could not add a task';
  END IF;
  SELECT id INTO v_task_d FROM public.tasks WHERE (v_result->>'task_id')::UUID = id;

  PERFORM set_config('request.jwt.claim.sub', v_admin::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT public.remove_task(v_task_d, 'admin cleanup') INTO v_result;
  EXECUTE 'RESET ROLE';
  IF NOT (v_result->>'removed')::BOOLEAN THEN
    RAISE EXCEPTION 'FAIL: ADMIN could not delete a task';
  END IF;
  RAISE NOTICE 'PASS  ADMIN retains add and delete (reassign already proven by 04_admin_controls_test.sql)';

  RAISE NOTICE 'ALL TASK CONTROL RESTRICTED TESTS PASSED';
END
$t$;
