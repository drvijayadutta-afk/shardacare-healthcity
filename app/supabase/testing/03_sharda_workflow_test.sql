-- ============================================================================
-- LOCAL TEST ONLY — walks the real Sharda workflow and asserts the actual
-- people, not just that the graph is connected.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_wf UUID; v_job UUID; v_work UUID; v_res JSONB;
  v_stage TEXT; v_who TEXT; v_path TEXT := ''; v_guard INT := 0;
  v_designer UUID;
BEGIN
  SELECT id INTO v_wf FROM public.workflow_templates WHERE name='Sharda Marketing Workflow';
  IF v_wf IS NULL THEN RAISE EXCEPTION 'Sharda workflow missing'; END IF;

  SELECT id INTO v_designer FROM public.users WHERE full_name='Jaggi';

  INSERT INTO public.jobs (name, category) VALUES ('Cardiology campaign','department')
  RETURNING id INTO v_job;

  -- No PO on this one: should go FINAL_APPROVAL -> PRODUCTION directly.
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, po_required)
  SELECT v_job, v_wf, id, 'Cardiac OPD poster',
         (SELECT id FROM public.users WHERE full_name='Sushant'),
         (SELECT id FROM public.users WHERE full_name='Sushant'),
         'IN_PROGRESS', FALSE
  FROM public.workflow_stages WHERE workflow_id=v_wf AND name='LEADERSHIP_BRIEF'
  RETURNING id INTO v_work;

  -- Who will do the work. resolve_next_assignee picks a collaborator holding
  -- the stage's expected role, so these determine the routing.
  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role)
  SELECT v_work, id, 'COLLABORATOR' FROM public.users
  WHERE full_name IN ('Sushant','Vijaya','Jaggi','Indu');

  INSERT INTO public.files (work_item_id, file_name, storage_path)
  VALUES (v_work,'artwork.pdf','x/artwork.pdf');

  LOOP
    v_guard := v_guard + 1; EXIT WHEN v_guard > 30;

    SELECT s.name, COALESCE(u.full_name,'(nobody)')
      INTO v_stage, v_who
    FROM public.work_items w
    JOIN public.workflow_stages s ON s.id = w.current_stage_id
    LEFT JOIN public.users u ON u.id = w.current_assignee_id
    WHERE w.id = v_work;

    EXIT WHEN v_stage IS NULL;
    v_path := v_path || v_stage || ' [' || v_who || '] > ';
    EXIT WHEN v_stage = 'COMPLETED';
    -- Since 0014 the PO runs beside the work rather than in front of it, and
    -- release is the one thing that still waits for it. The gate blocks the
    -- move INTO release, so procurement has to be cleared while the item is
    -- still upstream — which is exactly the parallelism being tested.
    IF (SELECT po_request_id FROM public.work_items WHERE id=v_work) IS NOT NULL
       AND (SELECT po_status FROM public.work_items WHERE id=v_work)
           NOT IN ('RELEASED','NOT_REQUIRED') THEN
      PERFORM set_config('request.jwt.claim.sub', NULL, TRUE);
      PERFORM public.advance_po_track(v_work, 'IN_REVIEW');
      PERFORM public.advance_po_track(v_work, 'APPROVED');
      PERFORM public.advance_po_track(v_work, 'RELEASED');
    END IF;

    PERFORM set_config('request.jwt.claim.sub',
      (SELECT COALESCE(current_assignee_id, owner_id)::TEXT
       FROM public.work_items WHERE id=v_work), TRUE);

    IF (SELECT approval_required FROM public.work_items WHERE id=v_work) THEN
      v_res := public.approve_work_item(v_work, NULL);
    ELSE
      v_res := public.submit_for_next_stage(v_work, NULL);
    END IF;
  END LOOP;

  RAISE NOTICE '%', rtrim(v_path,' > ');

  -- The people, not just the shape
  IF v_path NOT LIKE '%CONTENT [Vijaya]%'        THEN RAISE EXCEPTION 'CONTENT did not route to Vijaya: %', v_path; END IF;
  IF v_path NOT LIKE '%DESIGN [Jaggi]%'          THEN RAISE EXCEPTION 'DESIGN did not route to the designer: %', v_path; END IF;
  IF v_path NOT LIKE '%CONTENT_REVIEW [Vijaya]%' THEN RAISE EXCEPTION 'Vijaya does not review everything: %', v_path; END IF;
  IF v_path NOT LIKE '%MANAGER_APPROVAL [Sushant]%'
     AND v_path NOT LIKE '%MANAGER_APPROVAL [Nirmal]%'
     THEN RAISE EXCEPTION 'MANAGER_APPROVAL did not route to a manager: %', v_path; END IF;
  IF v_path NOT LIKE '%FINAL_APPROVAL [Parul]%'  THEN RAISE EXCEPTION 'FINAL_APPROVAL did not route to Parul: %', v_path; END IF;
  IF v_path NOT LIKE '%RELEASE [Indu]%'          THEN RAISE EXCEPTION 'RELEASE did not route to Indu: %', v_path; END IF;
  IF v_path LIKE '%PO_REQUEST%'                  THEN RAISE EXCEPTION 'no-PO item detoured through procurement'; END IF;
  IF (SELECT status FROM public.work_items WHERE id=v_work) <> 'COMPLETED'
     THEN RAISE EXCEPTION 'did not complete'; END IF;

  RAISE NOTICE 'PASS  no-PO path routed to the right person at every stage';
END
$t$;

-- ---------------------------------------------------------------------------
-- PO path, and a rejection from Parul
-- ---------------------------------------------------------------------------
DO $t2$
DECLARE
  v_wf UUID; v_work UUID; v_res JSONB; v_stage TEXT; v_path TEXT := ''; v_guard INT := 0;
BEGIN
  SELECT id INTO v_wf FROM public.workflow_templates WHERE name='Sharda Marketing Workflow';

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, po_required)
  SELECT (SELECT id FROM public.jobs WHERE name='Cardiology campaign'), v_wf, id,
         'Hoarding at gate 1',
         (SELECT id FROM public.users WHERE full_name='Sushant'),
         (SELECT id FROM public.users WHERE full_name='Sushant'),
         'IN_PROGRESS', TRUE
  FROM public.workflow_stages WHERE workflow_id=v_wf AND name='LEADERSHIP_BRIEF'
  RETURNING id INTO v_work;

  INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role)
  SELECT v_work, id, 'COLLABORATOR' FROM public.users
  WHERE full_name IN ('Sushant','Vijaya','Vidisha','Indu');
  INSERT INTO public.files (work_item_id, file_name, storage_path)
  VALUES (v_work,'hoarding.pdf','x/h.pdf');

  LOOP
    v_guard := v_guard + 1; EXIT WHEN v_guard > 30;
    SELECT s.name INTO v_stage FROM public.work_items w
    JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;
    EXIT WHEN v_stage IS NULL;
    v_path := v_path || v_stage || ' > ';
    EXIT WHEN v_stage = 'COMPLETED';
    -- Since 0014 the PO runs beside the work rather than in front of it, and
    -- release is the one thing that still waits for it. The gate blocks the
    -- move INTO release, so procurement has to be cleared while the item is
    -- still upstream — which is exactly the parallelism being tested.
    IF (SELECT po_request_id FROM public.work_items WHERE id=v_work) IS NOT NULL
       AND (SELECT po_status FROM public.work_items WHERE id=v_work)
           NOT IN ('RELEASED','NOT_REQUIRED') THEN
      PERFORM set_config('request.jwt.claim.sub', NULL, TRUE);
      PERFORM public.advance_po_track(v_work, 'IN_REVIEW');
      PERFORM public.advance_po_track(v_work, 'APPROVED');
      PERFORM public.advance_po_track(v_work, 'RELEASED');
    END IF;
    PERFORM set_config('request.jwt.claim.sub',
      (SELECT COALESCE(current_assignee_id, owner_id)::TEXT FROM public.work_items WHERE id=v_work), TRUE);
    IF (SELECT approval_required FROM public.work_items WHERE id=v_work) THEN
      v_res := public.approve_work_item(v_work, NULL);
    ELSE
      v_res := public.submit_for_next_stage(v_work, NULL);
    END IF;
  END LOOP;

  RAISE NOTICE '%', rtrim(v_path,' > ');
  -- Since 0014 procurement is a PARALLEL track, not a detour. Approval goes
  -- straight to production and the PO opens beside it, so the old assertion
  -- (FINAL_APPROVAL > PO_REQUEST > ... > PRODUCTION) now describes behaviour
  -- that would be a regression if it came back.
  IF v_path NOT LIKE '%FINAL_APPROVAL > PRODUCTION%'
    THEN RAISE EXCEPTION 'PO work should go straight to production: %', v_path; END IF;
  IF v_path LIKE '%PO_REQUEST%'
    THEN RAISE EXCEPTION 'procurement is back on the critical path: %', v_path; END IF;
  IF (SELECT po_status FROM public.work_items WHERE id=v_work) = 'NOT_STARTED'
    THEN RAISE EXCEPTION 'PO track did not open alongside'; END IF;
  IF (SELECT po_request_id FROM public.work_items WHERE id=v_work) IS NULL
    THEN RAISE EXCEPTION 'no PO raised'; END IF;
  RAISE NOTICE 'PASS  PO runs in parallel; production did not wait for it';
END
$t2$;

DO $t3$
DECLARE
  v_wf UUID; v_work UUID; v_parul UUID; v_stage TEXT;
BEGIN
  SELECT id INTO v_wf FROM public.workflow_templates WHERE name='Sharda Marketing Workflow';
  SELECT id INTO v_parul FROM public.users WHERE full_name='Parul';

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, approval_required)
  SELECT (SELECT id FROM public.jobs WHERE name='Cardiology campaign'), v_wf, id,
         'Rejected piece', v_parul, v_parul, 'PENDING', TRUE
  FROM public.workflow_stages WHERE workflow_id=v_wf AND name='FINAL_APPROVAL'
  RETURNING id INTO v_work;

  PERFORM set_config('request.jwt.claim.sub', v_parul::TEXT, TRUE);
  PERFORM public.request_changes(v_work, 'Logo too small');

  SELECT s.name INTO v_stage FROM public.work_items w
  JOIN public.workflow_stages s ON s.id=w.current_stage_id WHERE w.id=v_work;

  IF v_stage <> 'DESIGN' THEN
    RAISE EXCEPTION 'Parul rejecting sent work to % — should go back to DESIGN', v_stage;
  END IF;
  RAISE NOTICE 'PASS  Parul requesting changes returns work to DESIGN';
END
$t3$;

SELECT 'ALL SHARDA WORKFLOW TESTS PASSED' AS result;
