-- ============================================================================
-- LOCAL TEST ONLY — 0020_restrict_job_creation.sql. Proves the database
-- refuses non-admins, including the self-attribution path that a role-only
-- check would have missed (created_by = auth.uid() on jobs_write).
--
-- Unlike the other suites, this exercises raw table RLS rather than a
-- SECURITY INVOKER function's own internal role check -- and RLS is enforced
-- against the actual Postgres role running the query, not against the
-- auth.uid() GUC. psql here connects as the postgres superuser, which
-- bypasses RLS entirely regardless of that GUC. So every statement that must
-- actually be checked runs under `SET ROLE authenticated` (what PostgREST
-- itself connects as in real Supabase), with `RESET ROLE` back to postgres
-- for setup work in between.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_admin UUID; v_manager UUID; v_coord UUID; v_plain UUID;
  v_wf UUID; v_job UUID; v_stage UUID; v_work UUID;
  v_failed BOOLEAN;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('jc-admin@t.test','{"full_name":"JcAdmin"}')     RETURNING id INTO v_admin;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('jc-manager@t.test','{"full_name":"JcManager"}') RETURNING id INTO v_manager;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('jc-coord@t.test','{"full_name":"JcCoord"}')     RETURNING id INTO v_coord;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('jc-plain@t.test','{"full_name":"JcPlain"}')     RETURNING id INTO v_plain;

  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_admin, id FROM public.roles WHERE name='ADMIN';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_manager, id FROM public.roles WHERE name='WORKFLOW_MANAGER';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_coord, id FROM public.roles WHERE name='COORDINATOR';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_plain, id FROM public.roles WHERE name='CREATOR';

  SELECT id INTO v_wf FROM public.workflow_templates WHERE name='Sharda Marketing Workflow';
  SELECT id INTO v_stage FROM public.workflow_stages
  WHERE workflow_id=v_wf AND name='LEADERSHIP_BRIEF';

  -- ---- WORKFLOW_MANAGER may not create a job -----------------------------
  PERFORM set_config('request.jwt.claim.sub', v_manager::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.jobs (name, category, created_by) VALUES ('Manager job', 'department', v_manager);
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a WORKFLOW_MANAGER was allowed to create a job'; END IF;
  RAISE NOTICE 'PASS  WORKFLOW_MANAGER cannot create a job';

  -- ---- COORDINATOR may not create a job -----------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_coord::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.jobs (name, category, created_by) VALUES ('Coord job', 'department', v_coord);
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a COORDINATOR was allowed to create a job'; END IF;
  RAISE NOTICE 'PASS  COORDINATOR cannot create a job';

  -- ---- The self-attribution loophole is closed: a plain user cannot create
  -- a job even by naming themselves as created_by. This is the case a bare
  -- role-list change would have missed entirely.
  PERFORM set_config('request.jwt.claim.sub', v_plain::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.jobs (name, category, created_by) VALUES ('Self-attributed job', 'department', v_plain);
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a plain user created a job via created_by self-attribution'; END IF;
  RAISE NOTICE 'PASS  the created_by self-attribution loophole is closed';

  -- ---- A plain user may not insert a work item either (still authenticated,
  -- still v_plain from the block above) ------------------------------------
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name, status)
    VALUES (gen_random_uuid(), v_wf, v_stage, 'Should not exist', 'PENDING');
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: a plain user inserted a work item'; END IF;
  RAISE NOTICE 'PASS  a plain user cannot insert a work item';

  -- ---- ADMIN can still do both ---------------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_admin::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  INSERT INTO public.jobs (name, category, created_by) VALUES ('Admin job', 'department', v_admin)
  RETURNING id INTO v_job;

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name, status, owner_id, created_by)
  VALUES (v_job, v_wf, v_stage, 'Admin work item', 'PENDING', v_admin, v_admin)
  RETURNING id INTO v_work;
  EXECUTE 'RESET ROLE';

  IF v_job IS NULL OR v_work IS NULL THEN
    RAISE EXCEPTION 'FAIL: ADMIN could not create a job and work item';
  END IF;
  RAISE NOTICE 'PASS  ADMIN can still create a job and its first work item';

  -- ---- A requester can still update a job they are attached to (jobs_modify,
  -- unchanged by this migration). ADMIN attaches v_plain as requester_id
  -- first -- a plain user cannot grant themselves that, and should not be
  -- able to; this is testing jobs_modify, not another way around jobs_insert.
  UPDATE public.jobs SET requester_id = v_plain WHERE id = v_job;

  PERFORM set_config('request.jwt.claim.sub', v_plain::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  UPDATE public.jobs SET description = 'edited by requester' WHERE id = v_job;
  EXECUTE 'RESET ROLE';
  IF (SELECT description FROM public.jobs WHERE id = v_job) <> 'edited by requester' THEN
    RAISE EXCEPTION 'FAIL: a requester could not update a job they are attached to';
  END IF;
  RAISE NOTICE 'PASS  a requester can still update a job they are attached to';

  RAISE NOTICE 'ALL JOB CREATION TESTS PASSED';
END
$t$;
