-- ============================================================================
-- LOCAL TEST HARNESS ONLY — proves the handoff engine, not just the DDL.
-- Run against a database that already has 00_auth_shim + 0001..0007 applied.
-- Every assertion RAISEs on failure, so a clean run means everything passed.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = WARNING;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
DO $fixtures$
DECLARE
  v_designer   UUID;
  v_designer2  UUID;
  v_approver   UUID;
  v_coord      UUID;
  v_wf         UUID;
  v_brief      UUID;
  v_design     UUID;
  v_approval   UUID;
  v_po         UUID;
  v_prod       UUID;
  v_job        UUID;
BEGIN
  -- Users (auth.users trigger creates the public.users rows)
  INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('designer@example.test',  '{"full_name":"Designer One"}')   RETURNING id INTO v_designer;
  INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('designer2@example.test', '{"full_name":"Designer Two"}')   RETURNING id INTO v_designer2;
  INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('approver@example.test',  '{"full_name":"Approver One"}')   RETURNING id INTO v_approver;
  INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('coord@example.test',     '{"full_name":"Coordinator One"}') RETURNING id INTO v_coord;

  INSERT INTO public.user_roles (user_id, role_id)
    SELECT v_designer,  id FROM public.roles WHERE name = 'CREATOR';
  INSERT INTO public.user_roles (user_id, role_id)
    SELECT v_designer2, id FROM public.roles WHERE name = 'CREATOR';
  INSERT INTO public.user_roles (user_id, role_id)
    SELECT v_approver,  id FROM public.roles WHERE name = 'APPROVER';
  INSERT INTO public.user_roles (user_id, role_id)
    SELECT v_coord,     id FROM public.roles WHERE name = 'COORDINATOR';

  -- Workflow: Brief -> Design -> Approval -> (PO?) -> Production -> done
  -- is_default FALSE: 0008_default_workflow.sql already owns the default slot,
  -- and idx_workflow_templates_one_default permits exactly one.
  INSERT INTO public.workflow_templates (name, multi_owner_behavior, is_default)
    VALUES ('Standard Creative', 'SINGLE', FALSE) RETURNING id INTO v_wf;

  INSERT INTO public.workflow_stages (workflow_id, name, stage_order, sla_days)
    VALUES (v_wf, 'BRIEF', 1, 1) RETURNING id INTO v_brief;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order, sla_days, expected_role_id)
    VALUES (v_wf, 'DESIGN', 2, 3, (SELECT id FROM public.roles WHERE name='CREATOR'))
    RETURNING id INTO v_design;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order, sla_days, requires_approval, approval_category)
    VALUES (v_wf, 'APPROVAL', 3, 2, TRUE, 'branding') RETURNING id INTO v_approval;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order, sla_days)
    VALUES (v_wf, 'PO', 4, 2) RETURNING id INTO v_po;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order, sla_days, is_terminal)
    VALUES (v_wf, 'PRODUCTION', 5, 5, TRUE) RETURNING id INTO v_prod;

  INSERT INTO public.workflow_transitions (workflow_id, from_stage_id, to_stage_id, trigger_condition) VALUES
    (v_wf, v_brief,    v_design,  'SUBMISSION'),
    (v_wf, v_design,   v_approval,'SUBMISSION'),
    (v_wf, v_approval, v_po,      'PO_REQUIRED'),
    (v_wf, v_approval, v_prod,    'NO_PO'),
    (v_wf, v_approval, v_design,  'CHANGES_REQUIRED'),
    (v_wf, v_po,       v_prod,    'SUBMISSION'),
    (v_wf, v_prod,     NULL,      'SUBMISSION');

  -- Approval routing is DATA: 'branding' work goes to whoever this row names.
  INSERT INTO public.approval_authorities (approver_id, work_category, approval_level)
    VALUES (v_approver, 'branding', 1);

  -- Priority-specific SLA
  INSERT INTO public.stage_sla_config (stage_id, priority, sla_days)
    VALUES (v_approval, 'CRITICAL', 1);

  INSERT INTO public.jobs (name, category, requester_id, created_by)
    VALUES ('Clinic Branding', 'branding', v_coord, v_coord) RETURNING id INTO v_job;

  -- Stash ids for the assertions below
  CREATE TEMP TABLE _t (k TEXT PRIMARY KEY, v UUID);
  INSERT INTO _t VALUES
    ('designer',v_designer), ('designer2',v_designer2), ('approver',v_approver),
    ('coord',v_coord), ('wf',v_wf), ('brief',v_brief), ('design',v_design),
    ('approval',v_approval), ('po',v_po), ('prod',v_prod), ('job',v_job);
END
$fixtures$;

-- ---------------------------------------------------------------------------
-- TEST 1 — submit advances the stage and routes to the CONFIGURED approver
-- ---------------------------------------------------------------------------
DO $test1$
DECLARE
  v_work UUID; v_res JSONB;
  v_designer UUID := (SELECT v FROM _t WHERE k='designer');
  v_approver UUID := (SELECT v FROM _t WHERE k='approver');
BEGIN
  INSERT INTO public.work_items (job_id, name, workflow_id, current_stage_id,
                                 owner_id, current_assignee_id, pending_with_id,
                                 status, priority, created_by)
  VALUES ((SELECT v FROM _t WHERE k='job'), 'Signage design',
          (SELECT v FROM _t WHERE k='wf'), (SELECT v FROM _t WHERE k='design'),
          v_designer, v_designer, v_designer, 'IN_PROGRESS', 'MEDIUM',
          (SELECT v FROM _t WHERE k='coord'))
  RETURNING id INTO v_work;

  INSERT INTO public.tasks (work_item_id, stage_id, assignee_id, title)
  VALUES (v_work, (SELECT v FROM _t WHERE k='design'), v_designer, 'Signage design — DESIGN');

  PERFORM set_config('request.jwt.claim.sub', v_designer::TEXT, TRUE);
  v_res := public.submit_for_next_stage(v_work, 'First draft ready');

  IF (v_res->>'advanced')::BOOLEAN IS NOT TRUE THEN
    RAISE EXCEPTION 'T1 FAIL: did not advance: %', v_res;
  END IF;
  IF v_res->>'to_stage' <> 'APPROVAL' THEN
    RAISE EXCEPTION 'T1 FAIL: expected APPROVAL, got %', v_res->>'to_stage';
  END IF;
  -- The approver was never named in code — it was looked up from approval_authorities
  IF (v_res->>'next_assignee_id')::UUID <> v_approver THEN
    RAISE EXCEPTION 'T1 FAIL: wrong assignee %', v_res->>'next_assignee_id';
  END IF;

  -- A task must exist for the NEXT person, and the submitter's must be closed
  IF NOT EXISTS (SELECT 1 FROM public.tasks
                 WHERE work_item_id=v_work AND assignee_id=v_approver
                   AND closed_at IS NULL AND action_type='APPROVE') THEN
    RAISE EXCEPTION 'T1 FAIL: no open APPROVE task for approver';
  END IF;
  IF EXISTS (SELECT 1 FROM public.tasks
             WHERE work_item_id=v_work AND assignee_id=v_designer AND closed_at IS NULL) THEN
    RAISE EXCEPTION 'T1 FAIL: submitter task still open';
  END IF;

  -- pending_with must follow the ball
  IF (SELECT pending_with_id FROM public.work_items WHERE id=v_work) <> v_approver THEN
    RAISE EXCEPTION 'T1 FAIL: pending_with_id did not move to approver';
  END IF;

  IF (SELECT COUNT(*) FROM public.submissions WHERE work_item_id=v_work) <> 1 THEN
    RAISE EXCEPTION 'T1 FAIL: submission not recorded';
  END IF;
  IF (SELECT COUNT(*) FROM public.activity_log WHERE work_item_id=v_work) < 3 THEN
    RAISE EXCEPTION 'T1 FAIL: expected >=3 activity rows, got %',
      (SELECT COUNT(*) FROM public.activity_log WHERE work_item_id=v_work);
  END IF;
  IF (SELECT COUNT(*) FROM public.notifications
      WHERE work_item_id=v_work AND recipient_id=v_approver) <> 1 THEN
    RAISE EXCEPTION 'T1 FAIL: approver not notified';
  END IF;

  INSERT INTO _t VALUES ('work1', v_work);
  RAISE NOTICE 'T1 PASS  submit -> stage advanced, approver resolved from config, task+notification created';
END
$test1$;

-- ---------------------------------------------------------------------------
-- TEST 2 — Request Changes returns it to the last submitter, keeping history
-- ---------------------------------------------------------------------------
DO $test2$
DECLARE
  v_work UUID := (SELECT v FROM _t WHERE k='work1');
  v_designer UUID := (SELECT v FROM _t WHERE k='designer');
  v_approver UUID := (SELECT v FROM _t WHERE k='approver');
  v_res JSONB;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_approver::TEXT, TRUE);
  v_res := public.request_changes(v_work, 'Logo is too small');

  IF v_res->>'returned_to_stage' <> 'DESIGN' THEN
    RAISE EXCEPTION 'T2 FAIL: expected DESIGN, got %', v_res->>'returned_to_stage';
  END IF;
  IF (v_res->>'assigned_to')::UUID <> v_designer THEN
    RAISE EXCEPTION 'T2 FAIL: not returned to original submitter';
  END IF;
  -- The earlier submission must survive the round trip
  IF (SELECT COUNT(*) FROM public.submissions WHERE work_item_id=v_work) <> 1 THEN
    RAISE EXCEPTION 'T2 FAIL: prior submission was lost';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.comments
                 WHERE work_item_id=v_work AND comment_type='CHANGE_REQUEST') THEN
    RAISE EXCEPTION 'T2 FAIL: no change-request comment';
  END IF;
  IF (SELECT status FROM public.work_items WHERE id=v_work) <> 'CHANGES_REQUIRED' THEN
    RAISE EXCEPTION 'T2 FAIL: status not CHANGES_REQUIRED';
  END IF;
  RAISE NOTICE 'T2 PASS  request_changes -> back to DESIGN, original submitter, history intact';
END
$test2$;

-- ---------------------------------------------------------------------------
-- TEST 3 — PO branching is data-driven (same stage, two destinations)
-- ---------------------------------------------------------------------------
DO $test3$
DECLARE
  v_a UUID; v_b UUID; v_res JSONB;
  v_approver UUID := (SELECT v FROM _t WHERE k='approver');
BEGIN
  -- Item A: po_required = FALSE  -> PRODUCTION
  INSERT INTO public.work_items (job_id, name, workflow_id, current_stage_id, owner_id,
                                 current_assignee_id, status, priority, po_required, created_by)
  VALUES ((SELECT v FROM _t WHERE k='job'), 'No-PO item', (SELECT v FROM _t WHERE k='wf'),
          (SELECT v FROM _t WHERE k='approval'), v_approver, v_approver,
          'PENDING', 'MEDIUM', FALSE, (SELECT v FROM _t WHERE k='coord'))
  RETURNING id INTO v_a;

  -- Item B: po_required = TRUE   -> PO
  INSERT INTO public.work_items (job_id, name, workflow_id, current_stage_id, owner_id,
                                 current_assignee_id, status, priority, po_required, created_by)
  VALUES ((SELECT v FROM _t WHERE k='job'), 'PO item', (SELECT v FROM _t WHERE k='wf'),
          (SELECT v FROM _t WHERE k='approval'), v_approver, v_approver,
          'PENDING', 'MEDIUM', TRUE, (SELECT v FROM _t WHERE k='coord'))
  RETURNING id INTO v_b;

  PERFORM set_config('request.jwt.claim.sub', v_approver::TEXT, TRUE);

  v_res := public.submit_for_next_stage(v_a, NULL);
  IF v_res->>'to_stage' <> 'PRODUCTION' THEN
    RAISE EXCEPTION 'T3 FAIL: no-PO item went to % (expected PRODUCTION)', v_res->>'to_stage';
  END IF;

  v_res := public.submit_for_next_stage(v_b, NULL);
  IF v_res->>'to_stage' <> 'PO' THEN
    RAISE EXCEPTION 'T3 FAIL: PO item went to % (expected PO)', v_res->>'to_stage';
  END IF;

  RAISE NOTICE 'T3 PASS  PO branch chosen from data, not code';
END
$test3$;

-- ---------------------------------------------------------------------------
-- TEST 4 — PARALLEL work waits for every collaborator
-- ---------------------------------------------------------------------------
DO $test4$
DECLARE
  v_wf UUID; v_s1 UUID; v_s2 UUID; v_work UUID; v_res JSONB;
  v_d1 UUID := (SELECT v FROM _t WHERE k='designer');
  v_d2 UUID := (SELECT v FROM _t WHERE k='designer2');
BEGIN
  INSERT INTO public.workflow_templates (name, multi_owner_behavior)
    VALUES ('Parallel Creative', 'PARALLEL') RETURNING id INTO v_wf;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order, sla_days)
    VALUES (v_wf, 'DESIGN', 1, 3) RETURNING id INTO v_s1;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order, sla_days, is_terminal)
    VALUES (v_wf, 'DONE', 2, 1, TRUE) RETURNING id INTO v_s2;
  INSERT INTO public.workflow_transitions (workflow_id, from_stage_id, to_stage_id, trigger_condition)
    VALUES (v_wf, v_s1, v_s2, 'SUBMISSION');

  INSERT INTO public.work_items (job_id, name, workflow_id, current_stage_id, owner_id,
                                 current_assignee_id, status, priority, created_by)
  VALUES ((SELECT v FROM _t WHERE k='job'), 'NABH Signages', v_wf, v_s1, v_d1, v_d1,
          'IN_PROGRESS','MEDIUM',(SELECT v FROM _t WHERE k='coord'))
  RETURNING id INTO v_work;

  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role) VALUES
    (v_work, v_d1, 'PRIMARY'), (v_work, v_d2, 'COLLABORATOR');

  -- First collaborator submits — must NOT advance
  PERFORM set_config('request.jwt.claim.sub', v_d1::TEXT, TRUE);
  v_res := public.submit_for_next_stage(v_work, 'my half');
  IF (v_res->>'advanced')::BOOLEAN IS NOT FALSE THEN
    RAISE EXCEPTION 'T4 FAIL: advanced with a collaborator still pending';
  END IF;
  IF (SELECT current_stage_id FROM public.work_items WHERE id=v_work) <> v_s1 THEN
    RAISE EXCEPTION 'T4 FAIL: stage moved early';
  END IF;

  -- Second submits — now it advances
  PERFORM set_config('request.jwt.claim.sub', v_d2::TEXT, TRUE);
  v_res := public.submit_for_next_stage(v_work, 'my half too');
  IF (v_res->>'advanced')::BOOLEAN IS NOT TRUE THEN
    RAISE EXCEPTION 'T4 FAIL: did not advance after all submitted: %', v_res;
  END IF;

  RAISE NOTICE 'T4 PASS  PARALLEL gate held, then released';
END
$test4$;

-- ---------------------------------------------------------------------------
-- TEST 5 — a user who does not hold the work cannot submit it
-- ---------------------------------------------------------------------------
DO $test5$
DECLARE
  v_work UUID := (SELECT v FROM _t WHERE k='work1');
  v_stranger UUID;
  v_ok BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('stranger@example.test','{"full_name":"Stranger"}') RETURNING id INTO v_stranger;

  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  BEGIN
    PERFORM public.submit_for_next_stage(v_work, 'not mine');
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := TRUE;
  END;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'T5 FAIL: a stranger was allowed to submit';
  END IF;
  RAISE NOTICE 'T5 PASS  non-holder rejected';
END
$test5$;

-- ---------------------------------------------------------------------------
-- TEST 6 — on hold blocks submission until resumed
-- ---------------------------------------------------------------------------
DO $test6$
DECLARE
  v_work UUID := (SELECT v FROM _t WHERE k='work1');
  v_designer UUID := (SELECT v FROM _t WHERE k='designer');
  v_blocked BOOLEAN := FALSE;
BEGIN
  -- Since 0013, holding work is reserved to the status controllers. A designer
  -- must be refused; the hold itself is then done by someone who may.
  PERFORM set_config('request.jwt.claim.sub', v_designer::TEXT, TRUE);
  DECLARE v_refused BOOLEAN := FALSE;
  BEGIN
    BEGIN
      PERFORM public.put_on_hold(v_work, 'Waiting on client copy', 'info_needed');
    EXCEPTION WHEN insufficient_privilege THEN
      v_refused := TRUE;
    END;
    IF NOT v_refused THEN
      RAISE EXCEPTION 'T6 FAIL: a designer was allowed to put work on hold';
    END IF;
  END;

  -- A real controller, created the way 0013 expects them to exist: by holding
  -- STATUS_CONTROLLER, not by being named in code.
  DECLARE v_controller UUID;
  BEGIN
    INSERT INTO auth.users (email, raw_user_meta_data)
      VALUES ('controller@example.test','{"full_name":"Controller"}')
      RETURNING id INTO v_controller;
    INSERT INTO public.user_roles (user_id, role_id)
      SELECT v_controller, id FROM public.roles WHERE name='STATUS_CONTROLLER'
      ON CONFLICT DO NOTHING;
    PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  END;

  PERFORM public.put_on_hold(v_work, 'Waiting on client copy', 'info_needed');

  IF (SELECT status FROM public.work_items WHERE id=v_work) <> 'ON_HOLD' THEN
    RAISE EXCEPTION 'T6 FAIL: status not ON_HOLD';
  END IF;
  -- The stage must be preserved so it resumes where it stopped
  IF (SELECT current_stage_id FROM public.work_items WHERE id=v_work) IS NULL THEN
    RAISE EXCEPTION 'T6 FAIL: hold destroyed the stage';
  END IF;

  BEGIN
    PERFORM public.submit_for_next_stage(v_work, 'sneaky');
  EXCEPTION WHEN OTHERS THEN
    v_blocked := TRUE;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'T6 FAIL: submitted while on hold';
  END IF;

  PERFORM public.resume_work(v_work);
  IF (SELECT status FROM public.work_items WHERE id=v_work) = 'ON_HOLD' THEN
    RAISE EXCEPTION 'T6 FAIL: resume did not clear hold';
  END IF;

  RAISE NOTICE 'T6 PASS  hold reserved to controllers, blocks submit, resume works';
END
$test6$;

-- ---------------------------------------------------------------------------
-- TEST 7 — RLS: a user sees only their own tasks through v_my_tasks
-- ---------------------------------------------------------------------------
DO $test7$
DECLARE
  v_designer UUID := (SELECT v FROM _t WHERE k='designer');
  v_approver UUID := (SELECT v FROM _t WHERE k='approver');
  v_leak INT;
BEGIN
  -- Impersonate the approver as a non-superuser role so RLS is enforced
  PERFORM set_config('request.jwt.claim.sub', v_approver::TEXT, TRUE);
  SET LOCAL ROLE authenticated;

  SELECT COUNT(*) INTO v_leak
  FROM public.v_my_tasks
  WHERE assignee_id <> v_approver;

  RESET ROLE;

  IF v_leak > 0 THEN
    RAISE EXCEPTION 'T7 FAIL: v_my_tasks leaked % rows belonging to other users', v_leak;
  END IF;
  RAISE NOTICE 'T7 PASS  v_my_tasks returns only the caller''s rows';
END
$test7$;

-- ---------------------------------------------------------------------------
-- TEST 8 — config tables are not writable by a non-admin
-- ---------------------------------------------------------------------------
DO $test8$
DECLARE
  v_designer UUID := (SELECT v FROM _t WHERE k='designer');
  v_rows INT;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_designer::TEXT, TRUE);
  SET LOCAL ROLE authenticated;

  -- RLS turns a forbidden UPDATE into a no-op rather than an error
  UPDATE public.approval_authorities SET approval_level = 99;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RESET ROLE;

  IF v_rows > 0 THEN
    RAISE EXCEPTION 'T8 FAIL: non-admin rewrote the approval chain (% rows)', v_rows;
  END IF;
  RAISE NOTICE 'T8 PASS  approval chain is admin-only';
END
$test8$;

-- ---------------------------------------------------------------------------
-- TEST 9 — no SLA configured means NO invented deadline
-- ---------------------------------------------------------------------------
DO $test9$
DECLARE
  v_wf UUID; v_s1 UUID; v_s2 UUID; v_work UUID; v_res JSONB;
  v_d1 UUID := (SELECT v FROM _t WHERE k='designer');
  v_deadline DATE;
BEGIN
  INSERT INTO public.workflow_templates (name) VALUES ('No SLA') RETURNING id INTO v_wf;
  -- sla_days deliberately left NULL
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order)
    VALUES (v_wf,'A',1) RETURNING id INTO v_s1;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order)
    VALUES (v_wf,'B',2) RETURNING id INTO v_s2;
  INSERT INTO public.workflow_transitions (workflow_id, from_stage_id, to_stage_id, trigger_condition)
    VALUES (v_wf, v_s1, v_s2, 'SUBMISSION');

  INSERT INTO public.work_items (job_id, name, workflow_id, current_stage_id, owner_id,
                                 current_assignee_id, status, created_by)
  VALUES ((SELECT v FROM _t WHERE k='job'),'Undated work', v_wf, v_s1, v_d1, v_d1,
          'IN_PROGRESS',(SELECT v FROM _t WHERE k='coord'))
  RETURNING id INTO v_work;

  PERFORM set_config('request.jwt.claim.sub', v_d1::TEXT, TRUE);
  v_res := public.submit_for_next_stage(v_work, NULL);

  SELECT stage_deadline INTO v_deadline FROM public.work_items WHERE id=v_work;
  IF v_deadline IS NOT NULL THEN
    RAISE EXCEPTION 'T9 FAIL: invented a deadline (%) when no SLA was configured', v_deadline;
  END IF;
  RAISE NOTICE 'T9 PASS  no SLA -> deadline left NULL, nothing invented';
END
$test9$;

-- ---------------------------------------------------------------------------
-- TEST 10 — a missing transition fails loudly instead of silently stalling
-- ---------------------------------------------------------------------------
DO $test10$
DECLARE
  v_wf UUID; v_s1 UUID; v_work UUID;
  v_d1 UUID := (SELECT v FROM _t WHERE k='designer');
  v_raised BOOLEAN := FALSE;
BEGIN
  INSERT INTO public.workflow_templates (name) VALUES ('Dead end') RETURNING id INTO v_wf;
  INSERT INTO public.workflow_stages (workflow_id, name, stage_order)
    VALUES (v_wf,'ONLY',1) RETURNING id INTO v_s1;
  -- no transitions at all

  INSERT INTO public.work_items (job_id, name, workflow_id, current_stage_id, owner_id,
                                 current_assignee_id, status, created_by)
  VALUES ((SELECT v FROM _t WHERE k='job'),'Stuck work', v_wf, v_s1, v_d1, v_d1,
          'IN_PROGRESS',(SELECT v FROM _t WHERE k='coord'))
  RETURNING id INTO v_work;

  PERFORM set_config('request.jwt.claim.sub', v_d1::TEXT, TRUE);
  BEGIN
    PERFORM public.submit_for_next_stage(v_work, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_raised := TRUE;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'T10 FAIL: missing transition did not raise';
  END IF;
  -- and the failure must have rolled back cleanly
  IF (SELECT current_stage_id FROM public.work_items WHERE id=v_work) <> v_s1 THEN
    RAISE EXCEPTION 'T10 FAIL: stage changed despite the error';
  END IF;
  RAISE NOTICE 'T10 PASS  misconfigured workflow raises and rolls back';
END
$test10$;

SELECT 'ALL TESTS PASSED' AS result;
