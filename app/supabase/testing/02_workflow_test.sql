-- ============================================================================
-- LOCAL TEST ONLY — drives a work item through the real 11-stage workflow.
-- Proves the configured routing table actually connects end to end, rather
-- than only that the INSERTs succeeded.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_req UUID; v_coord UUID; v_creator UUID; v_appr UUID; v_vendor UUID;
  v_wf UUID; v_job UUID; v_work UUID; v_res JSONB;
  v_stage TEXT;
  v_path TEXT := '';
  v_guard INT := 0;
BEGIN
  -- People
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('r@t.test','{"full_name":"Req"}')     RETURNING id INTO v_req;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('c@t.test','{"full_name":"Coord"}')   RETURNING id INTO v_coord;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('cr@t.test','{"full_name":"Creator"}') RETURNING id INTO v_creator;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('a@t.test','{"full_name":"Appr"}')    RETURNING id INTO v_appr;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('v@t.test','{"full_name":"Vend"}')    RETURNING id INTO v_vendor;

  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_req, id FROM public.roles WHERE name='REQUESTOR';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_coord, id FROM public.roles WHERE name='COORDINATOR';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_creator, id FROM public.roles WHERE name='CREATOR';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_appr, id FROM public.roles WHERE name='APPROVER';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_vendor, id FROM public.roles WHERE name='VENDOR';

  -- Approval routing for all three gates — configuration, not code
  INSERT INTO public.approval_authorities (approver_id, work_category, approval_level)
  VALUES (v_appr,'department',1), (v_appr,'po',1), (v_appr,'final',1);

  SELECT id INTO v_wf FROM public.workflow_templates WHERE name='Standard Marketing Workflow';

  INSERT INTO public.jobs (name, category, created_by)
  VALUES ('Flow test','department',v_coord) RETURNING id INTO v_job;

  -- ---- Case A: po_required = FALSE ------------------------------------
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, po_required, created_by)
  SELECT v_job, v_wf, id, 'No-PO path', v_creator, v_creator, 'IN_PROGRESS', FALSE, v_coord
  FROM public.workflow_stages WHERE workflow_id=v_wf AND name='REQUEST'
  RETURNING id INTO v_work;

  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role) VALUES
    (v_work, v_creator,'PRIMARY'), (v_work, v_coord,'COLLABORATOR'),
    (v_work, v_req,'SUPPORT'),     (v_work, v_vendor,'SUPPORT');

  -- Attachment for the two stages that require one
  INSERT INTO public.files (work_item_id, file_name, storage_path, uploaded_by)
  VALUES (v_work,'proof.pdf','x/proof.pdf',v_creator);

  LOOP
    v_guard := v_guard + 1;
    EXIT WHEN v_guard > 25;

    SELECT s.name INTO v_stage FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;
    EXIT WHEN v_stage IS NULL;
    v_path := v_path || v_stage || ' > ';
    EXIT WHEN v_stage = 'COMPLETED';

    -- Act as whoever currently holds it
    PERFORM set_config('request.jwt.claim.sub',
      (SELECT COALESCE(current_assignee_id, owner_id)::TEXT FROM public.work_items WHERE id=v_work), TRUE);

    IF (SELECT approval_required FROM public.work_items WHERE id=v_work) THEN
      v_res := public.approve_work_item(v_work, 'ok');
    ELSE
      v_res := public.submit_for_next_stage(v_work, NULL);
    END IF;
  END LOOP;

  RAISE NOTICE 'No-PO path: %', rtrim(v_path,' > ');

  IF v_path LIKE '%PO_REQUEST%' THEN
    RAISE EXCEPTION 'FAIL: no-PO item detoured through procurement';
  END IF;
  IF v_path NOT LIKE '%DEPARTMENT_APPROVAL > PRODUCTION%' THEN
    RAISE EXCEPTION 'FAIL: approval did not go straight to production: %', v_path;
  END IF;
  IF (SELECT status FROM public.work_items WHERE id=v_work) <> 'COMPLETED' THEN
    RAISE EXCEPTION 'FAIL: not COMPLETED, got %',
      (SELECT status FROM public.work_items WHERE id=v_work);
  END IF;
  IF (SELECT completed_at FROM public.work_items WHERE id=v_work) IS NULL THEN
    RAISE EXCEPTION 'FAIL: completed_at not stamped';
  END IF;
  IF EXISTS (SELECT 1 FROM public.tasks WHERE work_item_id=v_work AND closed_at IS NULL) THEN
    RAISE EXCEPTION 'FAIL: completed work still has an open task';
  END IF;
  IF (SELECT pending_with_id FROM public.work_items WHERE id=v_work) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: completed work is still pending with someone';
  END IF;

  -- ---- Case B: po_required = TRUE -------------------------------------
  v_path := ''; v_guard := 0;
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, po_required, created_by)
  SELECT v_job, v_wf, id, 'PO path', v_creator, v_creator, 'IN_PROGRESS', TRUE, v_coord
  FROM public.workflow_stages WHERE workflow_id=v_wf AND name='REQUEST'
  RETURNING id INTO v_work;

  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role) VALUES
    (v_work, v_creator,'PRIMARY'), (v_work, v_coord,'COLLABORATOR'),
    (v_work, v_req,'SUPPORT'),     (v_work, v_vendor,'SUPPORT');
  INSERT INTO public.files (work_item_id, file_name, storage_path, uploaded_by)
  VALUES (v_work,'proof.pdf','x/proof.pdf',v_creator);

  LOOP
    v_guard := v_guard + 1;
    EXIT WHEN v_guard > 25;
    SELECT s.name INTO v_stage FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;
    EXIT WHEN v_stage IS NULL;
    v_path := v_path || v_stage || ' > ';
    EXIT WHEN v_stage = 'COMPLETED';
    PERFORM set_config('request.jwt.claim.sub',
      (SELECT COALESCE(current_assignee_id, owner_id)::TEXT FROM public.work_items WHERE id=v_work), TRUE);
    IF (SELECT approval_required FROM public.work_items WHERE id=v_work) THEN
      v_res := public.approve_work_item(v_work, 'ok');
    ELSE
      v_res := public.submit_for_next_stage(v_work, NULL);
    END IF;
  END LOOP;

  RAISE NOTICE 'PO path:    %', rtrim(v_path,' > ');

  IF v_path NOT LIKE '%PO_REQUEST > PROCUREMENT_REVIEW > PO_APPROVAL > PO_RELEASED > PRODUCTION%' THEN
    RAISE EXCEPTION 'FAIL: procurement detour wrong: %', v_path;
  END IF;
  IF (SELECT status FROM public.work_items WHERE id=v_work) <> 'COMPLETED' THEN
    RAISE EXCEPTION 'FAIL: PO path did not complete';
  END IF;

  -- ---- Case C: approval gate with NO authority configured --------------
  -- Must park as unassigned and stay visible, not silently pick someone.
  DELETE FROM public.approval_authorities WHERE work_category='department';

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  SELECT v_job, v_wf, id, 'Unrouted approval', v_creator, v_creator, 'IN_PROGRESS', v_coord
  FROM public.workflow_stages WHERE workflow_id=v_wf AND name='INTERNAL_REVIEW'
  RETURNING id INTO v_work;

  PERFORM set_config('request.jwt.claim.sub', v_creator::TEXT, TRUE);
  v_res := public.submit_for_next_stage(v_work, NULL);

  IF (SELECT pending_with_label FROM public.work_items WHERE id=v_work) <> 'unassigned' THEN
    RAISE EXCEPTION 'FAIL: unrouted approval was not parked as unassigned (got %)',
      (SELECT pending_with_label FROM public.work_items WHERE id=v_work);
  END IF;
  IF (SELECT current_assignee_id FROM public.work_items WHERE id=v_work) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: an assignee was invented with no authority configured';
  END IF;
  RAISE NOTICE 'Unrouted approval parked as unassigned, not guessed';

  RAISE NOTICE 'ALL WORKFLOW TESTS PASSED';
END
$t$;
