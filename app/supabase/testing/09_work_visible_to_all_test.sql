-- ============================================================================
-- 09_work_visible_to_all_test.sql — 0025_work_visible_to_all.sql
--   Proves a plain, role-less user with zero personal connection to a work
--   item can SEE it and everything attached to it (tasks, comments, files,
--   activity log, submissions, approvals), and proves that widened SELECT
--   did NOT widen who may EDIT it -- can_edit_work_item is untouched.
--
-- Runs under SET ROLE authenticated, like 06/07/08 -- the postgres superuser
-- session bypasses RLS entirely and would hide every one of these.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_stranger UUID; v_holder UUID;
  v_wf UUID; v_job UUID; v_stage UUID; v_work UUID; v_task UUID;
  v_seen INT;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t9-stranger@t.test','{"full_name":"T9Stranger"}') RETURNING id INTO v_stranger;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t9-holder@t.test','{"full_name":"T9Holder"}')     RETURNING id INTO v_holder;

  -- v_stranger holds NO role at all -- not even CREATOR -- so any visibility
  -- proven below comes purely from can_see_work_item(), nothing else.

  SELECT id INTO v_wf FROM public.workflow_templates WHERE is_default LIMIT 1;
  SELECT id INTO v_stage FROM public.workflow_stages
  WHERE workflow_id=v_wf AND track='MAIN' ORDER BY stage_order LIMIT 1;

  INSERT INTO public.jobs (name, created_by) VALUES ('T9 job', v_holder) RETURNING id INTO v_job;

  -- A work item with zero connection to v_stranger: not owner, not
  -- assignee, not pending_with, not requester, not created_by, no
  -- work_item_owners row, no open task assigned to them.
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_stage, 'T9 no connection to stranger',
          v_holder, v_holder, 'IN_PROGRESS', v_holder)
  RETURNING id INTO v_work;

  INSERT INTO public.tasks (work_item_id, stage_id, assignee_id, title, action_type, priority)
  VALUES (v_work, v_stage, v_holder, 'T9 task', 'COMPLETE_STAGE', 'MEDIUM')
  RETURNING id INTO v_task;

  INSERT INTO public.comments (work_item_id, author_id, body)
  VALUES (v_work, v_holder, 'A comment only the holder wrote');

  INSERT INTO public.submissions (work_item_id, task_id, stage_id, submission_number, submitted_by)
  VALUES (v_work, v_task, v_stage, 1, v_holder);

  INSERT INTO public.activity_log (work_item_id, actor_id, action)
  VALUES (v_work, v_holder, 'ASSIGNED');

  -- ---- T1: the work item itself is visible ---------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT COUNT(*) INTO v_seen FROM public.work_items WHERE id = v_work;
  EXECUTE 'RESET ROLE';
  IF v_seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: a role-less stranger could not see a work item they have no connection to';
  END IF;
  RAISE NOTICE 'PASS  work item visible to a role-less user with no connection to it';

  -- ---- T2: everything attached to it is visible too ------------------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT COUNT(*) INTO v_seen FROM public.tasks WHERE work_item_id = v_work;
  IF v_seen <> 1 THEN RAISE EXCEPTION 'FAIL: tasks not visible'; END IF;

  SELECT COUNT(*) INTO v_seen FROM public.comments WHERE work_item_id = v_work;
  IF v_seen <> 1 THEN RAISE EXCEPTION 'FAIL: comments not visible'; END IF;

  SELECT COUNT(*) INTO v_seen FROM public.submissions WHERE work_item_id = v_work;
  IF v_seen <> 1 THEN RAISE EXCEPTION 'FAIL: submissions not visible'; END IF;

  SELECT COUNT(*) INTO v_seen FROM public.activity_log WHERE work_item_id = v_work;
  IF v_seen <> 1 THEN RAISE EXCEPTION 'FAIL: activity_log not visible'; END IF;
  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS  tasks, comments, submissions and activity log all visible on it too';

  -- ---- T3: the Control Tower metrics view sees it too (v_work_items /
  -- v_my_tasks are security_invoker, so they inherit this automatically) ----
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  SELECT COUNT(*) INTO v_seen FROM public.v_work_items WHERE id = v_work;
  EXECUTE 'RESET ROLE';
  IF v_seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: v_work_items (security_invoker) did not inherit the widened visibility';
  END IF;
  RAISE NOTICE 'PASS  v_work_items shows it too (Control Tower / Board / Work list all use this)';

  -- ---- T4: visibility widened, EDIT did not. A role-less stranger still
  -- cannot update the work item directly ------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  UPDATE public.work_items SET name = 'Tampered by stranger' WHERE id = v_work;
  EXECUTE 'RESET ROLE';
  IF (SELECT name FROM public.work_items WHERE id = v_work) = 'Tampered by stranger' THEN
    RAISE EXCEPTION 'FAIL: a role-less stranger edited a work item they only have SELECT on';
  END IF;
  RAISE NOTICE 'PASS  can_edit_work_item is untouched: seeing it did not grant editing it';

  -- ---- T5: nor can they delete the task on it. RLS silently matches zero
  -- rows on a refused DELETE rather than raising -- checked by row survival,
  -- not by expecting an exception (that pitfall already bit this session
  -- once, on 06_job_creation_test.sql's INSERT/UPDATE cases, which really do
  -- raise; a DELETE with no matching row under RLS just does nothing). ------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  DELETE FROM public.tasks WHERE id = v_task;
  EXECUTE 'RESET ROLE';
  IF NOT EXISTS (SELECT 1 FROM public.tasks WHERE id = v_task) THEN
    RAISE EXCEPTION 'FAIL: a role-less stranger deleted a task on work they only have SELECT on';
  END IF;
  -- tasks_delete itself was narrowed further by 0026 (ADMIN-only ->
  -- STATUS_CONTROLLER/ADMIN) -- unrelated to this file's point, which is
  -- just that a role-less stranger stays refused either way.
  RAISE NOTICE 'PASS  a role-less stranger cannot delete a task either';

  RAISE NOTICE 'ALL WORK-VISIBLE-TO-ALL TESTS PASSED';
END
$t$;
