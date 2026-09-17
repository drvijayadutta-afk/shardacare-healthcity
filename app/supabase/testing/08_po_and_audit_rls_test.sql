-- ============================================================================
-- 08_po_and_audit_rls_test.sql — 0023_po_and_audit_rls_fixes.sql
--   Proves: (1) a plain user cannot self-attribute a PO request with no
--   work_item_id at all; (2) a pure STATUS_CONTROLLER can now update a PO
--   they did not raise; (3) activity_log refuses an arbitrary actor_id.
--
-- T1 originally also asserted that a stranger could not self-attribute a PO
-- on a work item they had no connection to and could not SEE -- that stopped
-- being true once 0025_work_visible_to_all.sql made every work item visible
-- to every signed-in user (see that migration's own note: po_requests_insert
-- was gated on visibility specifically to stop a blind insert, so making
-- visibility universal makes that particular guard universally satisfied
-- too, as an intended side effect, not a regression). T1 now asserts the new
-- correct behavior instead of the old one.
--
-- Runs under SET ROLE authenticated, like 06 and 07 -- the postgres
-- superuser session bypasses RLS entirely and would hide every one of these.
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

DO $t$
DECLARE
  v_controller UUID; v_coord UUID; v_stranger UUID; v_holder UUID; v_admin UUID;
  v_wf UUID; v_job UUID; v_stage UUID; v_visible_work UUID; v_hidden_work UUID;
  v_po UUID; v_failed BOOLEAN;
BEGIN
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t8-controller@t.test','{"full_name":"T8Controller"}') RETURNING id INTO v_controller;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t8-coord@t.test','{"full_name":"T8Coord"}')           RETURNING id INTO v_coord;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t8-stranger@t.test','{"full_name":"T8Stranger"}')     RETURNING id INTO v_stranger;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t8-holder@t.test','{"full_name":"T8Holder"}')         RETURNING id INTO v_holder;
  INSERT INTO auth.users (email, raw_user_meta_data) VALUES
    ('t8-admin@t.test','{"full_name":"T8Admin"}')           RETURNING id INTO v_admin;

  -- STATUS_CONTROLLER only -- not also ADMIN/WORKFLOW_MANAGER/COORDINATOR.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_controller, id FROM public.roles WHERE name='STATUS_CONTROLLER';
  -- view_all via COORDINATOR, but no change_status.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_coord, id FROM public.roles WHERE name='COORDINATOR';
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_admin, id FROM public.roles WHERE name='ADMIN';

  SELECT id INTO v_wf FROM public.workflow_templates WHERE is_default LIMIT 1;
  SELECT id INTO v_stage FROM public.workflow_stages
  WHERE workflow_id=v_wf AND track='MAIN' ORDER BY stage_order LIMIT 1;

  INSERT INTO public.jobs (name, created_by) VALUES ('T8 job', v_holder) RETURNING id INTO v_job;

  -- A work item v_stranger owns/holds, and one they have no connection to at
  -- all (both are equally VISIBLE to v_stranger since 0025 -- the names
  -- describe personal connection, not RLS visibility, which is universal now).
  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_stage, 'T8 owned/held by stranger',
          v_stranger, v_stranger, 'IN_PROGRESS', v_stranger)
  RETURNING id INTO v_visible_work;

  INSERT INTO public.work_items (job_id, workflow_id, current_stage_id, name,
                                 owner_id, current_assignee_id, status, created_by)
  VALUES (v_job, v_wf, v_stage, 'T8 no connection to stranger',
          v_holder, v_holder, 'IN_PROGRESS', v_holder)
  RETURNING id INTO v_hidden_work;

  -- ---- T1: CAN self-attribute a PO on a work item with no personal
  -- connection at all -- work is universally visible since 0025, and
  -- po_requests_insert's visibility requirement is satisfied for everyone
  -- as a result. v_hidden_work has zero connection to v_stranger (not
  -- owner, assignee, creator, or task-holder) -- this is exactly the case
  -- that used to be refused. -----------------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  INSERT INTO public.po_requests (work_item_id, vendor_name, amount, raised_by)
  VALUES (v_hidden_work, 'No personal connection to this item', 999999, v_stranger)
  RETURNING id INTO v_po;
  EXECUTE 'RESET ROLE';
  IF v_po IS NULL THEN
    RAISE EXCEPTION 'FAIL: a person could not raise a PO on work that is now universally visible';
  END IF;
  RAISE NOTICE 'PASS  can self-attribute a PO on a work item with no personal connection (0025: work is visible to everyone)';

  -- ---- T2: naming a NULL work_item_id is refused too (the blindest form of
  -- the old bypass) --------------------------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.po_requests (work_item_id, vendor_name, amount, raised_by)
    VALUES (NULL, 'No work item at all', 1, v_stranger);
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: a stranger raised a PO with no work_item_id at all';
  END IF;
  RAISE NOTICE 'PASS  cannot self-attribute a PO with no work item at all';

  -- ---- T3: CAN raise a PO on a work item you can actually see ------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  INSERT INTO public.po_requests (work_item_id, vendor_name, amount, raised_by)
  VALUES (v_visible_work, 'Legit Vendor', 500, v_stranger)
  RETURNING id INTO v_po;
  EXECUTE 'RESET ROLE';
  IF v_po IS NULL THEN
    RAISE EXCEPTION 'FAIL: a person could not raise a PO on work they can actually see';
  END IF;
  RAISE NOTICE 'PASS  can still raise a PO on a work item you can see';

  -- ---- T4: someone with none of raised_by / ADMIN / WORKFLOW_MANAGER /
  -- COORDINATOR / change_status still cannot edit an unowned PO. (Note:
  -- COORDINATOR itself was already granted broad PO-edit access by the
  -- original po_requests_write, matching po_requests_select's design --
  -- that is unchanged and intentional, not part of this fix.)
  PERFORM set_config('request.jwt.claim.sub', v_holder::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  UPDATE public.po_requests SET vendor_name = 'Holder tampered' WHERE id = v_po;
  EXECUTE 'RESET ROLE';
  IF (SELECT vendor_name FROM public.po_requests WHERE id = v_po) = 'Holder tampered' THEN
    RAISE EXCEPTION 'FAIL: a role-less user edited a PO they did not raise';
  END IF;
  RAISE NOTICE 'PASS  a role-less, non-raiser is still refused on an unowned PO';

  -- ---- T5: a PURE STATUS_CONTROLLER (not ADMIN/WORKFLOW_MANAGER/
  -- COORDINATOR) CAN edit a PO they did not raise -- this is the fix -------
  PERFORM set_config('request.jwt.claim.sub', v_controller::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  UPDATE public.po_requests SET vendor_name = 'Controller override', amount = 750 WHERE id = v_po;
  EXECUTE 'RESET ROLE';
  IF (SELECT vendor_name FROM public.po_requests WHERE id = v_po) <> 'Controller override' THEN
    RAISE EXCEPTION 'FAIL: a pure STATUS_CONTROLLER could not update a PO they did not raise';
  END IF;
  RAISE NOTICE 'PASS  pure STATUS_CONTROLLER can update a PO they did not raise';

  -- ---- T6: activity_log refuses an arbitrary actor_id ---------------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
    VALUES (v_visible_work, v_admin, 'STAGE_CHANGED', '{"forged":true}');
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: a user inserted an activity_log row attributed to someone else';
  END IF;
  RAISE NOTICE 'PASS  cannot forge another user as actor_id in activity_log';

  -- ---- T7: a NULL actor_id (today's convention for some system inserts)
  -- and your own actor_id both still work ------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_stranger::TEXT, TRUE);
  EXECUTE 'SET ROLE authenticated';
  INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
  VALUES (v_visible_work, NULL, 'FILE_ATTACHED', '{"note":"null actor still allowed"}');
  INSERT INTO public.activity_log (work_item_id, actor_id, action, detail)
  VALUES (v_visible_work, v_stranger, 'FILE_ATTACHED', '{"note":"self actor still allowed"}');
  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS  NULL actor_id and self actor_id are both still accepted';

  RAISE NOTICE 'ALL PO AND AUDIT RLS TESTS PASSED';
END
$t$;
