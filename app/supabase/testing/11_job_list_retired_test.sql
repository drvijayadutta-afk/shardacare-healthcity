-- ============================================================================
-- 11_job_list_retired_test.sql — 0030_soft_delete_imported_job_list.sql
--   Proves the exact UPDATE logic that soft-deletes a joblist:-sourced job/
--   work item, while leaving anything else (a normal, hand-created job) live
--   and visible.
--
-- 0030 itself is a one-time data migration, not an ongoing invariant, so it
-- already ran (against whatever "joblist:" rows existed at the time) as part
-- of 01_schema.sql, before this suite's own fixtures exist -- unlike every
-- other suite, this one cannot just check the current state and expect it to
-- reflect a run that happened before its own data existed. Instead it seeds
-- its own "joblist:"-tagged fixture (simulating a row the original import
-- would have created and 0030 would have caught), then re-applies 0030's own
-- UPDATE statements directly -- which are themselves idempotent and side-
-- effect-free to re-run -- to prove the QUERY LOGIC is correct: it catches
-- exactly the joblist: pattern and nothing else.
--
-- Unlike the other suites this isn't testing RLS/permissions -- it's plain
-- data logic, so it runs as the connecting (superuser) role throughout.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_wf UUID; v_stage UUID;
  v_imported_job UUID; v_imported_item UUID;
  v_normal_job UUID; v_normal_item UUID;
BEGIN
  SELECT id INTO v_wf FROM public.workflow_templates WHERE is_default LIMIT 1;
  SELECT id INTO v_stage FROM public.workflow_stages
  WHERE workflow_id=v_wf AND track='MAIN' ORDER BY stage_order LIMIT 1;

  -- A fixture that LOOKS like the original import: source_ref matching the
  -- exact pattern 0030 targets.
  INSERT INTO public.jobs (name, source_ref)
  VALUES ('T11 fixture: simulated 10th Sept import', 'joblist:job:9999')
  RETURNING id INTO v_imported_job;

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name, status, source_ref)
  VALUES (v_imported_job, v_wf, v_stage, 'T11 fixture item', 'IN_PROGRESS', 'joblist:item:9999')
  RETURNING id INTO v_imported_item;

  -- A normal, hand-created job/work item -- no source_ref, exactly like
  -- anything a real user creates through New Work. Must NOT be touched.
  INSERT INTO public.jobs (name)
  VALUES ('T11 fixture: normal hand-created job')
  RETURNING id INTO v_normal_job;

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name, status)
  VALUES (v_normal_job, v_wf, v_stage, 'T11 fixture: normal work item', 'IN_PROGRESS')
  RETURNING id INTO v_normal_item;

  -- ---- Re-apply 0030's exact UPDATE logic -----------------------------------
  UPDATE public.jobs
     SET deleted_at = NOW()
   WHERE source_ref LIKE 'joblist:job:%'
     AND deleted_at IS NULL;

  UPDATE public.work_items
     SET deleted_at = NOW()
   WHERE source_ref LIKE 'joblist:item:%'
     AND deleted_at IS NULL;

  -- ---- T1: the joblist:-tagged fixture is soft-deleted ----------------------
  IF (SELECT deleted_at FROM public.jobs WHERE id = v_imported_job) IS NULL THEN
    RAISE EXCEPTION 'FAIL: a joblist:-tagged job was not soft-deleted';
  END IF;
  IF (SELECT deleted_at FROM public.work_items WHERE id = v_imported_item) IS NULL THEN
    RAISE EXCEPTION 'FAIL: a joblist:-tagged work item was not soft-deleted';
  END IF;
  RAISE NOTICE 'PASS  a joblist:-tagged job and work item are soft-deleted (deleted_at set)';

  -- ---- T2: it is a SOFT delete -- the row still exists, just hidden --------
  IF NOT EXISTS (SELECT 1 FROM public.jobs WHERE id = v_imported_job) THEN
    RAISE EXCEPTION 'FAIL: the job row was hard-deleted, not soft-deleted';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.work_items WHERE id = v_imported_item) THEN
    RAISE EXCEPTION 'FAIL: the work item row was hard-deleted, not soft-deleted';
  END IF;
  RAISE NOTICE 'PASS  the rows still exist -- this is a soft delete, recoverable';

  -- ---- T3: v_work_items (what Board/Control Tower/Work list/My Work read
  -- through) hides it -----------------------------------------------------
  IF EXISTS (SELECT 1 FROM public.v_work_items WHERE id = v_imported_item) THEN
    RAISE EXCEPTION 'FAIL: a soft-deleted joblist: work item is still visible via v_work_items';
  END IF;
  RAISE NOTICE 'PASS  the soft-deleted work item is invisible via v_work_items';

  -- ---- T4: a normal, hand-created job/work item is completely untouched ----
  IF (SELECT deleted_at FROM public.jobs WHERE id = v_normal_job) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: a normal, hand-created job was soft-deleted -- the pattern match is too broad';
  END IF;
  IF (SELECT deleted_at FROM public.work_items WHERE id = v_normal_item) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: a normal, hand-created work item was soft-deleted -- the pattern match is too broad';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.v_work_items WHERE id = v_normal_item) THEN
    RAISE EXCEPTION 'FAIL: a normal, hand-created work item disappeared from v_work_items';
  END IF;
  RAISE NOTICE 'PASS  a normal, hand-created job/work item is completely unaffected';

  -- ---- T5: re-applying is a no-op (idempotent) ------------------------------
  UPDATE public.jobs SET deleted_at = NOW()
   WHERE source_ref LIKE 'joblist:job:%' AND deleted_at IS NULL;
  IF (SELECT COUNT(*) FROM public.jobs WHERE id = v_imported_job AND deleted_at IS NULL) <> 0 THEN
    RAISE EXCEPTION 'FAIL: re-running the update somehow un-deleted the row';
  END IF;
  RAISE NOTICE 'PASS  re-applying the update is a safe no-op';

  RAISE NOTICE 'ALL JOB LIST RETIRED TESTS PASSED';
END
$t$;
