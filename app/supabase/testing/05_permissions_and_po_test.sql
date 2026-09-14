-- ============================================================================
-- 04_permissions_and_po_test.sql
--   Proves the rules added in 0015-0017, which the earlier suites only prove
--   were not BROKEN. Run after 00_auth_shim.sql against a local Postgres.
--
--     psql -f 00_auth_shim.sql
--     psql -f <all migrations>
--     psql -f 04_permissions_and_po_test.sql
--
--   Covers: who may do what, procurement running in parallel, the release
--   gate, tag de-duplication, and the creative chain's order.
-- ============================================================================

\set ON_ERROR_STOP on

DO $setup$
DECLARE
  v_wf UUID; v_job UUID; v_stage UUID;
BEGIN
  DROP TABLE IF EXISTS _p;
  CREATE TEMP TABLE _p (k TEXT PRIMARY KEY, v UUID);

  SELECT id INTO v_wf FROM public.workflow_templates WHERE is_default LIMIT 1;
  INSERT INTO _p VALUES ('wf', v_wf);

  -- People, by the roles the migrations actually key on. Find-or-create, so the
  -- suite can be re-run against the same database without tripping over its
  -- own fixtures.
  FOR v_stage IN SELECT NULL::UUID WHERE FALSE LOOP END LOOP;  -- keeps v_stage typed

  SELECT id INTO v_stage FROM auth.users WHERE email='t4.designer@example.test';
  IF v_stage IS NULL THEN
    INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('t4.designer@example.test', '{"full_name":"T4 Designer"}') RETURNING id INTO v_stage;
  END IF;
  INSERT INTO _p VALUES ('designer', v_stage);
  INSERT INTO public.user_roles (user_id, role_id)
    SELECT v_stage, id FROM public.roles WHERE name='DESIGNER' ON CONFLICT DO NOTHING;

  SELECT id INTO v_stage FROM auth.users WHERE email='t4.controller@example.test';
  IF v_stage IS NULL THEN
    INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('t4.controller@example.test', '{"full_name":"T4 Controller"}') RETURNING id INTO v_stage;
  END IF;
  INSERT INTO _p VALUES ('controller', v_stage);
  INSERT INTO public.user_roles (user_id, role_id)
    SELECT v_stage, id FROM public.roles WHERE name='STATUS_CONTROLLER' ON CONFLICT DO NOTHING;

  SELECT id INTO v_stage FROM auth.users WHERE email='t4.outsider@example.test';
  IF v_stage IS NULL THEN
    INSERT INTO auth.users (email, raw_user_meta_data)
    VALUES ('t4.outsider@example.test', '{"full_name":"T4 Outsider"}') RETURNING id INTO v_stage;
  END IF;
  INSERT INTO _p VALUES ('outsider', v_stage);
  INSERT INTO public.user_roles (user_id, role_id)
    SELECT v_stage, id FROM public.roles WHERE name='DESIGNER' ON CONFLICT DO NOTHING;

  INSERT INTO public.jobs (name, created_by)
  VALUES ('T4 job', (SELECT v FROM _p WHERE k='controller')) RETURNING id INTO v_job;
  INSERT INTO _p VALUES ('job', v_job);
END
$setup$;


-- ---------------------------------------------------------------------------
-- T1 — a designer may hand on their OWN finished work
--      (the literal reading of "only Vijaya and Nirmal" would break this, and
--       with it the whole designer -> Vijaya step of the stated chain)
-- ---------------------------------------------------------------------------
DO $t1$
DECLARE
  v_work UUID; v_first UUID;
  v_designer UUID := (SELECT v FROM _p WHERE k='designer');
  v_before TEXT; v_after TEXT;
BEGIN
  SELECT id INTO v_first FROM public.workflow_stages
  WHERE workflow_id=(SELECT v FROM _p WHERE k='wf') AND track='MAIN'
  ORDER BY stage_order LIMIT 1;

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES ((SELECT v FROM _p WHERE k='job'), (SELECT v FROM _p WHERE k='wf'), v_first,
          'T4 own work', v_designer, v_designer, 'IN_PROGRESS', v_designer)
  RETURNING id INTO v_work;
  INSERT INTO _p VALUES ('work', v_work);

  SELECT s.name INTO v_before FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;

  PERFORM set_config('request.jwt.claim.sub', v_designer::TEXT, TRUE);
  PERFORM public.submit_for_next_stage(v_work, 'done my bit');

  SELECT s.name INTO v_after FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;

  IF v_after = v_before THEN
    RAISE EXCEPTION 'T1 FAIL: a designer could not submit their own finished work';
  END IF;
  RAISE NOTICE 'T1 PASS  designer submitted own work: % -> %', v_before, v_after;
END
$t1$;


-- ---------------------------------------------------------------------------
-- T2 — a designer may NOT park, kill or override work
-- ---------------------------------------------------------------------------
DO $t2$
DECLARE
  v_work UUID := (SELECT v FROM _p WHERE k='work');
  v_designer UUID := (SELECT v FROM _p WHERE k='designer');
  v_refused BOOLEAN := FALSE;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_designer::TEXT, TRUE);

  BEGIN
    PERFORM public.put_on_hold(v_work, 'because I say so', 'other');
  EXCEPTION WHEN insufficient_privilege THEN v_refused := TRUE;
  END;
  IF NOT v_refused THEN RAISE EXCEPTION 'T2 FAIL: designer put work on hold'; END IF;

  v_refused := FALSE;
  BEGIN
    UPDATE public.work_items SET status='CANCELLED' WHERE id=v_work;
  EXCEPTION WHEN insufficient_privilege THEN v_refused := TRUE;
  END;
  IF NOT v_refused THEN RAISE EXCEPTION 'T2 FAIL: designer cancelled work'; END IF;

  RAISE NOTICE 'T2 PASS  designer refused hold and cancel';
END
$t2$;


-- ---------------------------------------------------------------------------
-- T3 — someone with no claim on the item may not move it at all
-- ---------------------------------------------------------------------------
DO $t3$
DECLARE
  v_work UUID := (SELECT v FROM _p WHERE k='work');
  v_outsider UUID := (SELECT v FROM _p WHERE k='outsider');
  v_refused BOOLEAN := FALSE;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_outsider::TEXT, TRUE);
  BEGIN
    PERFORM public.submit_for_next_stage(v_work, 'not mine at all');
  EXCEPTION WHEN insufficient_privilege THEN v_refused := TRUE;
  END;
  IF NOT v_refused THEN RAISE EXCEPTION 'T3 FAIL: an outsider moved the work'; END IF;
  RAISE NOTICE 'T3 PASS  outsider refused';
END
$t3$;


-- ---------------------------------------------------------------------------
-- T4 — the gate's registered approver may give a verdict; nobody else may
--      (this is what keeps Sushant and Parul able to verify)
-- ---------------------------------------------------------------------------
DO $t4$
DECLARE
  v_work UUID; v_gate UUID; v_cat TEXT; v_before TEXT; v_after TEXT;
  v_approver UUID; v_designer UUID := (SELECT v FROM _p WHERE k='designer');
  v_refused BOOLEAN := FALSE;
BEGIN
  -- Deliberately pick a gate whose approver is NOT a status controller. Vijaya
  -- holds both hats, so testing at her gate would prove nothing about whether
  -- being the registered approver is by itself enough — which is the entire
  -- point, because it is what lets Sushant and Parul verify.
  SELECT s.id, s.approval_category, aa.approver_id
    INTO v_gate, v_cat, v_approver
  FROM public.workflow_stages s
  JOIN public.approval_authorities aa
    ON aa.work_category = s.approval_category AND aa.is_active
  WHERE s.workflow_id = (SELECT v FROM _p WHERE k='wf')
    AND s.requires_approval
    AND NOT EXISTS (
      SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id
      WHERE ur.user_id = aa.approver_id AND r.permissions ? 'change_status')
  ORDER BY s.stage_order
  LIMIT 1;

  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'T4 FAIL: no gate has an approver who is not also a controller';
  END IF;

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status,
                                 approval_required, approval_status, created_by)
  VALUES ((SELECT v FROM _p WHERE k='job'), (SELECT v FROM _p WHERE k='wf'), v_gate,
          'T4 at a gate', v_approver, v_approver, 'IN_PROGRESS', TRUE, 'PENDING', v_approver)
  RETURNING id INTO v_work;

  SELECT s.name INTO v_before FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;

  -- A designer is not this gate's approver.
  PERFORM set_config('request.jwt.claim.sub', v_designer::TEXT, TRUE);
  BEGIN
    PERFORM public.approve_work_item(v_work, NULL);
  EXCEPTION WHEN OTHERS THEN v_refused := TRUE;
  END;
  IF NOT v_refused THEN RAISE EXCEPTION 'T4 FAIL: a non-approver approved at a gate'; END IF;

  -- The registered approver may, without holding change_status.
  PERFORM set_config('request.jwt.claim.sub', v_approver::TEXT, TRUE);
  IF public.can_change_status() THEN
    RAISE EXCEPTION 'T4 FAIL: fixture approver unexpectedly holds change_status';
  END IF;
  PERFORM public.approve_work_item(v_work, NULL);

  SELECT s.name INTO v_after FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;

  -- Assert the STAGE moved, not approval_status: when the next stage is also a
  -- gate the engine immediately sets PENDING again, so that field says nothing.
  IF v_after = v_before THEN
    RAISE EXCEPTION 'T4 FAIL: the registered approver could not approve (still at %)', v_before;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.approvals
                 WHERE work_item_id=v_work AND approver_id=v_approver AND outcome='APPROVED') THEN
    RAISE EXCEPTION 'T4 FAIL: approval was not recorded';
  END IF;

  RAISE NOTICE 'T4 PASS  gate approver judged % (% -> %); non-approver refused',
    v_cat, v_before, v_after;
END
$t4$;


-- ---------------------------------------------------------------------------
-- T5 — procurement opens ALONGSIDE the work, and release waits for it
-- ---------------------------------------------------------------------------
DO $t5$
DECLARE
  v_work UUID; v_fork UUID; v_dest TEXT; v_stage TEXT;
  v_controller UUID := (SELECT v FROM _p WHERE k='controller');
  v_blocked BOOLEAN := FALSE; v_guard INT := 0;
BEGIN
  SELECT from_stage_id INTO v_fork FROM public.workflow_transitions
  WHERE workflow_id=(SELECT v FROM _p WHERE k='wf') AND trigger_condition='PO_REQUIRED' LIMIT 1;

  IF v_fork IS NULL THEN RAISE EXCEPTION 'T5 FAIL: no PO fork in the default workflow'; END IF;

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status,
                                 po_required, approval_required, approval_status, created_by)
  SELECT (SELECT v FROM _p WHERE k='job'), (SELECT v FROM _p WHERE k='wf'), v_fork,
         'T4 PO work', v_controller, v_controller, 'IN_PROGRESS', TRUE,
         s.requires_approval,
         CASE WHEN s.requires_approval THEN 'PENDING' ELSE 'NOT_REQUIRED' END,
         v_controller
  FROM public.workflow_stages s WHERE s.id = v_fork
  RETURNING id INTO v_work;

  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  IF (SELECT approval_required FROM public.work_items WHERE id=v_work) THEN
    PERFORM public.approve_work_item(v_work, NULL);
  ELSE
    PERFORM public.submit_for_next_stage(v_work, NULL);
  END IF;

  SELECT s.name INTO v_dest FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;

  IF v_dest LIKE 'PO\_%' OR v_dest = 'PROCUREMENT_REVIEW' THEN
    RAISE EXCEPTION 'T5 FAIL: work went INTO procurement instead of past it (%)', v_dest;
  END IF;
  IF (SELECT po_request_id FROM public.work_items WHERE id=v_work) IS NULL THEN
    RAISE EXCEPTION 'T5 FAIL: the PO track did not open alongside';
  END IF;
  IF (SELECT po_status FROM public.work_items WHERE id=v_work) <> 'REQUESTED' THEN
    RAISE EXCEPTION 'T5 FAIL: PO status is %, expected REQUESTED',
      (SELECT po_status FROM public.work_items WHERE id=v_work);
  END IF;
  RAISE NOTICE 'T5a PASS  approved PO work went straight to %, PO opened beside it', v_dest;

  -- Some stages require an attachment before they can be submitted, which is a
  -- separate rule from procurement and would otherwise stop the walk early and
  -- look like the PO gate firing.
  INSERT INTO public.files (work_item_id, file_name, storage_path, uploaded_by)
  VALUES (v_work, 'artwork.pdf', v_work::text || '/artwork.pdf', v_controller);

  -- Walk on. The item must stall at the door of RELEASE, not before it.
  LOOP
    v_guard := v_guard + 1; EXIT WHEN v_guard > 20;
    SELECT s.name INTO v_stage FROM public.work_items w
      JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;
    EXIT WHEN v_stage = 'COMPLETED';

    PERFORM set_config('request.jwt.claim.sub',
      (SELECT COALESCE(current_assignee_id, owner_id)::TEXT
       FROM public.work_items WHERE id=v_work), TRUE);

    BEGIN
      IF (SELECT approval_required FROM public.work_items WHERE id=v_work) THEN
        PERFORM public.approve_work_item(v_work, NULL);
      ELSE
        PERFORM public.submit_for_next_stage(v_work, NULL);
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM LIKE '%purchase order%' THEN v_blocked := TRUE; EXIT; END IF;
      RAISE;
    END;
  END LOOP;

  IF NOT v_blocked THEN
    RAISE EXCEPTION 'T5 FAIL: work reached release with its PO still unissued';
  END IF;
  RAISE NOTICE 'T5b PASS  release held until the PO is issued';

  -- Clear procurement; release is now allowed.
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  PERFORM public.advance_po_track(v_work, 'IN_REVIEW');
  PERFORM public.advance_po_track(v_work, 'APPROVED');
  PERFORM public.advance_po_track(v_work, 'RELEASED');

  PERFORM set_config('request.jwt.claim.sub',
    (SELECT COALESCE(current_assignee_id, owner_id)::TEXT
     FROM public.work_items WHERE id=v_work), TRUE);
  PERFORM public.submit_for_next_stage(v_work, NULL);

  SELECT s.name INTO v_stage FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;
  IF v_stage NOT IN ('RELEASE','COMPLETED') THEN
    RAISE EXCEPTION 'T5 FAIL: still stuck at % after the PO was issued', v_stage;
  END IF;
  RAISE NOTICE 'T5c PASS  released once procurement cleared (now at %)', v_stage;
END
$t5$;


-- ---------------------------------------------------------------------------
-- T6 — a designer may NOT move the PO along
-- ---------------------------------------------------------------------------
DO $t6$
DECLARE
  v_work UUID; v_designer UUID := (SELECT v FROM _p WHERE k='designer');
  v_refused BOOLEAN := FALSE;
BEGIN
  SELECT id INTO v_work FROM public.work_items WHERE name='T4 PO work' LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub', v_designer::TEXT, TRUE);
  BEGIN
    PERFORM public.advance_po_track(v_work, 'REJECTED');
  EXCEPTION WHEN insufficient_privilege THEN v_refused := TRUE;
  END;
  IF NOT v_refused THEN RAISE EXCEPTION 'T6 FAIL: a designer moved the purchase order'; END IF;
  RAISE NOTICE 'T6 PASS  PO moves are reserved';
END
$t6$;


-- ---------------------------------------------------------------------------
-- T7 — tags: three spellings of one word are one tag
-- ---------------------------------------------------------------------------
DO $t7$
DECLARE
  v_work UUID := (SELECT v FROM _p WHERE k='work');
  v_controller UUID := (SELECT v FROM _p WHERE k='controller');
  v_n INT;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  PERFORM public.attach_tag(v_work, 'Hoarding');
  PERFORM public.attach_tag(v_work, 'hoarding');
  PERFORM public.attach_tag(v_work, '  HOARDING  ');

  SELECT COUNT(*) INTO v_n FROM public.work_item_tags WHERE work_item_id=v_work;
  IF v_n <> 1 THEN RAISE EXCEPTION 'T7 FAIL: % tags, expected 1', v_n; END IF;

  SELECT COUNT(*) INTO v_n FROM public.tags WHERE slug='hoarding';
  IF v_n <> 1 THEN RAISE EXCEPTION 'T7 FAIL: % tag rows for one word', v_n; END IF;

  -- The label keeps the first spelling typed, not the last.
  IF (SELECT label FROM public.tags WHERE slug='hoarding') <> 'Hoarding' THEN
    RAISE EXCEPTION 'T7 FAIL: label was overwritten by a later spelling';
  END IF;
  RAISE NOTICE 'T7 PASS  case and whitespace variants collapse to one tag';
END
$t7$;


-- ---------------------------------------------------------------------------
-- T8 — the creative chain is in the order the team described
-- ---------------------------------------------------------------------------
DO $t8$
DECLARE
  v_chain TEXT;
BEGIN
  SELECT string_agg(s.name, ' > ' ORDER BY s.stage_order) INTO v_chain
  FROM public.workflow_stages s
  JOIN public.workflow_templates w ON w.id = s.workflow_id
  WHERE w.name = 'Sharda Marketing Workflow' AND s.track = 'MAIN';

  IF v_chain NOT LIKE
    'LEADERSHIP_BRIEF > CONCEPT > CONTENT > DESIGN > CONTENT_REVIEW > MANAGER_APPROVAL > FINAL_APPROVAL%'
  THEN
    RAISE EXCEPTION 'T8 FAIL: creative chain is %', v_chain;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.workflow_stages s
    JOIN public.workflow_templates w ON w.id=s.workflow_id
    WHERE w.name='Sharda Marketing Workflow'
      AND s.name='CONTENT_REVIEW' AND s.requires_approval
      AND s.approval_category='proofread')
  THEN
    RAISE EXCEPTION 'T8 FAIL: Vijaya''s proofread is not a verification gate';
  END IF;

  RAISE NOTICE 'T8 PASS  concept > copy > design > proofread > managers > Parul';
END
$t8$;

DO $done$ BEGIN RAISE NOTICE 'ALL PERMISSION AND PO TESTS PASSED'; END $done$;
