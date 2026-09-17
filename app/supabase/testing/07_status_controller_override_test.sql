-- ============================================================================
-- 07_status_controller_override_test.sql — 0021 + 0022
--   Proves a STATUS_CONTROLLER (or ADMIN, via the same change_status
--   permission) can act on work that is neither theirs nor at their gate,
--   for real -- not just that enforce_status_change_permission()'s trigger
--   bypass exists, but that the row is actually reachable under RLS.
--
-- Why this suite exists: 0015 added public.can_change_status() and wired it
-- into the enforce_status_change_permission() trigger, but never into
-- can_see_work_item() / can_edit_work_item() -- the functions behind the
-- work_items_select / work_items_update RLS policies. A Postgres
-- `SELECT ... FOR UPDATE` (which approve_work_item, request_changes and
-- submit_for_next_stage all open with) is checked against BOTH the SELECT
-- policy and the UPDATE policy, so a plain STATUS_CONTROLLER's row was
-- filtered out before the trigger's own bypass was ever reached -- it just
-- looked like "Work item not found". This was invisible in the existing
-- suites because 05_permissions_and_po_test.sql runs as the postgres
-- superuser (which bypasses RLS entirely) with no SET ROLE, so it only ever
-- exercised the plpgsql-level checks, never RLS. 0022 fixes the RLS
-- functions; this suite is what actually would have caught it -- it runs the
-- same way 06_job_creation_test.sql does, under SET ROLE authenticated.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_controller UUID; v_coord UUID; v_stranger UUID; v_holder UUID;
  v_wf UUID; v_job UUID; v_main_stage UUID; v_approval_stage UUID;
  v_approver UUID; v_cat TEXT;
  v_submit_work UUID; v_approve_work UUID;
  v_before TEXT; v_after TEXT;
  v_failed BOOLEAN;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('sc7-controller@t.test','{"full_name":"Sc7Controller"}') RETURNING id INTO v_controller;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('sc7-coord@t.test','{"full_name":"Sc7Coord"}')           RETURNING id INTO v_coord;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('sc7-stranger@t.test','{"full_name":"Sc7Stranger"}')     RETURNING id INTO v_stranger;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('sc7-holder@t.test','{"full_name":"Sc7Holder"}')         RETURNING id INTO v_holder;

  -- v_controller: STATUS_CONTROLLER ONLY -- deliberately not also ADMIN,
  -- WORKFLOW_MANAGER or COORDINATOR, which is exactly the case that was
  -- silently broken (an account like this passing every other check would
  -- still have looked fine in a test that granted extra roles).
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_controller, id FROM public.roles WHERE name='STATUS_CONTROLLER';

  -- v_coord: has view_all (so it is RLS-visible via has_role) but not
  -- change_status -- proves the fix did not just open the tables wide open.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_coord, id FROM public.roles WHERE name='COORDINATOR';

  SELECT id INTO v_wf FROM public.workflow_templates WHERE is_default LIMIT 1;
  SELECT id INTO v_main_stage FROM public.workflow_stages
  WHERE workflow_id=v_wf AND track='MAIN' ORDER BY stage_order LIMIT 1;

  -- A gate whose registered approver is not v_controller or v_coord.
  SELECT s.id, s.approval_category, aa.approver_id
    INTO v_approval_stage, v_cat, v_approver
  FROM public.workflow_stages s
  JOIN public.approval_authorities aa
    ON aa.work_category = s.approval_category AND aa.is_active
  WHERE s.workflow_id = v_wf AND s.requires_approval
    AND aa.approver_id NOT IN (v_controller, v_coord)
  ORDER BY s.stage_order LIMIT 1;

  IF v_approval_stage IS NULL THEN
    RAISE EXCEPTION 'SETUP FAIL: no approval gate found with a distinct approver';
  END IF;

  INSERT INTO public.jobs (name, created_by) VALUES ('SC7 job', v_holder) RETURNING id INTO v_job;

  -- Work item at a plain (non-approval) stage, held by v_holder -- neither
  -- v_controller nor v_coord holds it.
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_main_stage, 'SC7 submit target',
          v_holder, v_holder, 'IN_PROGRESS', v_holder)
  RETURNING id INTO v_submit_work;

  -- Work item sitting at the approval gate, also held by v_holder.
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status,
                                 approval_required, approval_status, created_by)
  VALUES (v_job, v_wf, v_approval_stage, 'SC7 approve target',
          v_holder, v_holder, 'IN_PROGRESS', TRUE, 'PENDING', v_holder)
  RETURNING id INTO v_approve_work;

  -- ---- Negative: a stranger with no roles at all, refused on both --------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    PERFORM public.submit_for_next_stage(v_submit_work, 'stranger, should be refused');
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a stranger moved work they have no claim on'; END IF;
  RAISE NOTICE 'PASS  stranger refused on submit_for_next_stage';

  -- ---- Negative: COORDINATOR (view_all, RLS-visible, but no change_status,
  -- and not holding this item) still refused on both -----------------------
  PERFORM set_config('request.jwt.claim.sub', v_coord::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    PERFORM public.submit_for_next_stage(v_submit_work, 'coordinator, should be refused');
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a COORDINATOR without change_status moved work they do not hold'; END IF;
  RAISE NOTICE 'PASS  coordinator (view_all but no change_status) refused on submit_for_next_stage';

  PERFORM set_config('request.jwt.claim.sub', v_coord::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    PERFORM public.approve_work_item(v_approve_work, 'coordinator, should be refused');
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a COORDINATOR without change_status approved work at someone else''s gate'; END IF;
  RAISE NOTICE 'PASS  coordinator (view_all but no change_status) refused on approve_work_item';

  -- ---- Positive: a PURE STATUS_CONTROLLER (not ADMIN/WORKFLOW_MANAGER/
  -- COORDINATOR, not the holder) can submit work that is neither theirs nor
  -- at their gate -----------------------------------------------------------
  SELECT s.name INTO v_before FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_submit_work;

  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  PERFORM public.submit_for_next_stage(v_submit_work, 'controller override');
  EXECUTE 'RESET ROLE';

  SELECT s.name INTO v_after FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_submit_work;
  IF v_after = v_before THEN
    RAISE EXCEPTION 'FAIL: a pure STATUS_CONTROLLER could not submit work they do not hold (still at %)', v_before;
  END IF;
  RAISE NOTICE 'PASS  pure STATUS_CONTROLLER submitted work they do not hold: % -> %', v_before, v_after;

  -- ---- Positive: the same controller can give a verdict at a gate that is
  -- not theirs to approve --------------------------------------------------
  SELECT s.name INTO v_before FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_approve_work;

  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  PERFORM public.approve_work_item(v_approve_work, 'controller override');
  EXECUTE 'RESET ROLE';

  SELECT s.name INTO v_after FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_approve_work;
  IF v_after = v_before THEN
    RAISE EXCEPTION 'FAIL: a pure STATUS_CONTROLLER could not approve work at a gate that is not theirs (still at %)', v_before;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.approvals
                 WHERE work_item_id=v_approve_work AND approver_id=v_controller AND outcome='APPROVED') THEN
    RAISE EXCEPTION 'FAIL: the controller''s approval was not recorded';
  END IF;
  RAISE NOTICE 'PASS  pure STATUS_CONTROLLER approved % gate that is not theirs: % -> %', v_cat, v_before, v_after;

  RAISE NOTICE 'ALL STATUS CONTROLLER OVERRIDE TESTS PASSED';
END
$t$;
