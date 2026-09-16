-- ============================================================================
-- 00_diagnose.sql — what state is this database actually in?
-- ============================================================================
-- Read-only. Run it in the SQL Editor when the app shows nothing and you need
-- to know whether the cause is the schema, the seed, your account, or RLS.
-- ============================================================================

SELECT
  step,
  result,
  CASE WHEN ok THEN 'OK' ELSE 'ACTION NEEDED' END AS status,
  fix
FROM (
  SELECT 1 AS n, '1. Schema applied (base, up to migration 0012)' AS step,
    (SELECT COUNT(*)::text FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE') || ' tables' AS result,
    (SELECT COUNT(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE') >= 21 AS ok,
    'Run 01_schema.sql' AS fix

  UNION ALL SELECT 2, '2. users.id can self-generate',
    COALESCE((SELECT column_default FROM information_schema.columns
      WHERE table_schema='public' AND table_name='users' AND column_name='id'),'no default'),
    (SELECT column_default FROM information_schema.columns
      WHERE table_schema='public' AND table_name='users' AND column_name='id') IS NOT NULL,
    'Run 0010_repair_users_identity.sql — an older schema left this unset and the seed cannot insert'

  UNION ALL SELECT 3, '3. Seed imported',
    (SELECT COUNT(*)::text FROM public.work_items) || ' work items',
    (SELECT COUNT(*) FROM public.work_items) > 0,
    'Run 02_seed.sql. If it errors on users.id, do step 2 first'

  UNION ALL SELECT 4, '4. Workflow configured',
    (SELECT COUNT(*)::text FROM public.workflow_stages) || ' stages, ' ||
    (SELECT COUNT(*)::text FROM public.workflow_transitions) || ' transitions',
    (SELECT COUNT(*) FROM public.workflow_transitions) > 0,
    'Re-run 01_schema.sql — migration 0008 defines these'

  UNION ALL SELECT 5, '5. You have a person row',
    COALESCE((SELECT email FROM public.users
       WHERE id = auth.uid()), 'none for auth.uid()=' || COALESCE(auth.uid()::text,'NULL')),
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid()),
    'Run 03_first_user.sql. NOTE: in the SQL Editor auth.uid() is NULL, so this line is only meaningful from the app'

  UNION ALL SELECT 6, '6. Roles assigned to someone',
    (SELECT COUNT(*)::text FROM public.user_roles) || ' role assignments',
    (SELECT COUNT(*) FROM public.user_roles) > 0,
    'Run 03_first_user.sql'

  UNION ALL SELECT 7, '7. Approval routing',
    (SELECT COUNT(*)::text FROM public.approval_authorities WHERE is_active) || ' gates configured',
    (SELECT COUNT(*) FROM public.approval_authorities WHERE is_active) > 0,
    'Run 03_first_user.sql — without this, approvals park as unassigned'

  UNION ALL SELECT 8, '8. Work assigned to anyone',
    (SELECT COUNT(*)::text FROM public.tasks WHERE closed_at IS NULL) || ' open tasks',
    TRUE,   -- zero is EXPECTED, not a fault
    'Zero is correct after import: the source document named no assignee for 31 of 38 items. My Work shows only YOUR tasks; use the Control Tower to see everything'

  -- ---- Everything below is migrations 0013-0020. If step 1 looks fine but
  -- these show ACTION NEEDED, you are on an older schema snapshot: paste the
  -- CURRENT database/supabase-bundle/01_schema.sql in full and re-run it.
  -- It is idempotent, so re-running the whole thing is always safe.
  UNION ALL SELECT 9, '9. Admin task controls (0013)',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.routines
      WHERE routine_schema='public' AND routine_name='reassign_work_item')
      THEN 'present' ELSE 'missing' END,
    EXISTS (SELECT 1 FROM information_schema.routines
      WHERE routine_schema='public' AND routine_name='reassign_work_item'),
    'Reassign/add/delete-task on Work Detail need this. Re-paste and re-run 01_schema.sql'

  UNION ALL SELECT 10, '10. Attachments, tags, status control (0015)',
    (SELECT COUNT(*)::text FROM information_schema.tables
      WHERE table_schema='public' AND table_name IN ('tags','work_item_tags')) || ' of 2 tables present, ' ||
    CASE WHEN EXISTS (SELECT 1 FROM storage.buckets WHERE id='work-files')
      THEN 'bucket present' ELSE 'bucket MISSING' END,
    (SELECT COUNT(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_name IN ('tags','work_item_tags')) = 2
      AND EXISTS (SELECT 1 FROM storage.buckets WHERE id='work-files'),
    'Tags, file uploads, comment threads and "only Vijaya/Nirmal move stages" all need this. Re-paste and re-run 01_schema.sql'

  UNION ALL SELECT 11, '11. Parallel PO track (0016)',
    -- po_request_id itself dates back to 0004 (always present) -- advance_po_track
    -- and the track column are what 0016 actually adds, so those are what
    -- distinguishes "PO runs in parallel" from the older detour-style flow.
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.routines
      WHERE routine_schema='public' AND routine_name='advance_po_track')
      THEN 'present' ELSE 'missing' END,
    EXISTS (SELECT 1 FROM information_schema.routines
      WHERE routine_schema='public' AND routine_name='advance_po_track')
      AND EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='workflow_stages' AND column_name='track'),
    'PO tracking on Work Detail needs this. Re-paste and re-run 01_schema.sql'

  UNION ALL SELECT 12, '12. Creative chain / CONCEPT stage (0017)',
    CASE WHEN EXISTS (SELECT 1 FROM public.workflow_stages WHERE name='CONCEPT')
      THEN 'present' ELSE 'missing' END,
    EXISTS (SELECT 1 FROM public.workflow_stages WHERE name='CONCEPT'),
    'Re-paste and re-run 01_schema.sql'

  UNION ALL SELECT 13, '13. Journey view (0019)',
    CASE WHEN EXISTS (SELECT 1 FROM information_schema.views
      WHERE table_schema='public' AND table_name='v_work_item_journey')
      THEN 'present' ELSE 'missing' END,
    EXISTS (SELECT 1 FROM information_schema.views
      WHERE table_schema='public' AND table_name='v_work_item_journey'),
    'The Journey column on the Work list and Work Detail needs this. Re-paste and re-run 01_schema.sql'

  UNION ALL SELECT 14, '14. Job creation restricted to ADMIN (0020)',
    COALESCE((SELECT with_check FROM pg_policies
      WHERE schemaname='public' AND tablename='jobs' AND policyname='jobs_insert'), 'policy MISSING'),
    EXISTS (SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='jobs' AND policyname='jobs_insert'
        AND with_check ILIKE '%ADMIN%' AND with_check NOT ILIKE '%WORKFLOW_MANAGER%'),
    'If this is missing or still mentions WORKFLOW_MANAGER/COORDINATOR, you are on the schema from before this restriction. Re-paste and re-run 01_schema.sql'
) t
ORDER BY n;

-- ----------------------------------------------------------------------------
-- Accounts that can actually sign in
-- ----------------------------------------------------------------------------
SELECT
  u.email,
  string_agg(r.name, ', ' ORDER BY r.name)                      AS roles,
  CASE WHEN a.id IS NULL THEN 'no login (imported name only)'
       ELSE 'can sign in' END                                   AS login
FROM public.users u
LEFT JOIN public.user_roles ur ON ur.user_id = u.id
LEFT JOIN public.roles r       ON r.id = ur.role_id
LEFT JOIN auth.users a         ON a.id = u.id
GROUP BY u.id, u.email, a.id
ORDER BY (a.id IS NULL), u.email;
