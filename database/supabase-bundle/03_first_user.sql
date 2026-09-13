-- ============================================================================
-- 03_first_user.sql — turn a Supabase auth user into a working admin
--
-- RUN THIS AFTER:
--   1. 01_schema.sql
--   2. 02_seed.sql
--   3. creating a user in Supabase → Authentication → Users → Add user
--      (tick "Auto Confirm User", or you cannot sign in)
--
-- EDIT THE EMAIL ON THE NEXT LINE, then run the whole file.
-- ============================================================================

DO $$
DECLARE
  -- The master account. Change this if you want a different admin.
  v_email      TEXT := 'drvijayadutta@gmail.com';

  v_user_id    UUID;
  v_full_name  TEXT;
  v_roles      INT;
BEGIN
  SELECT id, COALESCE(raw_user_meta_data->>'full_name', split_part(email,'@',1))
    INTO v_user_id, v_full_name
  FROM auth.users WHERE lower(email) = lower(v_email);

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION
      'No auth user with email "%". Create one first: Authentication → Users → Add user (tick Auto Confirm User).',
      v_email;
  END IF;

  -- Backfill the profile row.
  --
  -- handle_new_auth_user() creates this automatically, but only for users
  -- created AFTER 01_schema.sql ran. Anyone added before that has an auth
  -- account with no profile, which makes the app sign you in and then fail to
  -- find you. This covers that case; it is a no-op in the normal order.
  --
  -- A person imported from the job list already has a users row keyed by a
  -- random id, not by their auth id. Relinking that row means repointing every
  -- FK that references it, so this refuses rather than creating a second
  -- identity for the same person -- two rows, work split silently between them.
  IF EXISTS (SELECT 1 FROM public.users WHERE lower(email) = lower(v_email)
               AND id <> v_user_id) THEN
    RAISE EXCEPTION
      'A person row already exists for "%" with a different id. It was probably imported from the job list. Relink it instead: UPDATE public.users SET id = ''%'' WHERE lower(email) = lower(''%''); -- then re-run this script.',
      v_email, v_user_id, v_email;
  END IF;

  INSERT INTO public.users (id, email, full_name)
  VALUES (v_user_id, v_email, v_full_name)
  ON CONFLICT (id) DO NOTHING;

  -- Master control: every operational role at once. ADMIN alone is enough for
  -- the RLS policies, but COORDINATOR and APPROVER are granted too so this
  -- account can create work and clear approval gates without a second user.
  --
  -- The Control Tower is restricted to ADMIN / WORKFLOW_MANAGER / COORDINATOR
  -- because its totals run under RLS: for a CREATOR they would silently narrow
  -- to that person's own work rather than showing nothing.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT v_user_id, id FROM public.roles
  WHERE name IN ('ADMIN', 'WORKFLOW_MANAGER', 'COORDINATOR', 'APPROVER')
  ON CONFLICT (user_id, role_id) DO NOTHING;

  -- Make this person the approver for all three gates.
  --
  -- Without at least one approval_authorities row per category, work reaching
  -- an approval stage has nobody to route to: the engine parks it as
  -- 'unassigned' and surfaces it on the Control Tower rather than picking
  -- someone arbitrarily. That is correct behaviour, but it means handoffs stop
  -- dead until these rows exist. Reassign them to the real approvers later --
  -- it is an UPDATE, not a deploy.
  INSERT INTO public.approval_authorities (approver_id, work_category, approval_level)
  SELECT v_user_id, c, 1
  FROM (VALUES ('department'), ('po'), ('final')) AS t(c)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_authorities a
    WHERE a.work_category = t.c AND a.is_active
  );

  SELECT COUNT(*) INTO v_roles FROM public.user_roles WHERE user_id = v_user_id;

  RAISE NOTICE '% is set up with % role(s). Sign in at your app URL.', v_email, v_roles;
END $$;

-- ============================================================================
-- Check it worked
-- ============================================================================
SELECT
  u.email,
  u.full_name,
  string_agg(r.name, ', ' ORDER BY r.name)                        AS roles,
  (SELECT COUNT(*) FROM public.approval_authorities
    WHERE approver_id = u.id)                                     AS approval_gates
FROM public.users u
LEFT JOIN public.user_roles ur ON ur.user_id = u.id
LEFT JOIN public.roles r       ON r.id = ur.role_id
WHERE u.email NOT LIKE '%@placeholder.invalid'
GROUP BY u.id, u.email, u.full_name;

-- ============================================================================
-- Your queue will be EMPTY after signing in, and that is correct.
--
-- 31 of the 38 imported work items have no assignee, because the source
-- document named nobody for them. My Work shows tasks assigned to you, and
-- nothing has been assigned yet.
--
-- To see the imported work, open /control-tower (all 38) or /work?filter=all.
-- To put something in your own queue, pick a work item and give yourself a
-- task on it -- replace the id below with one from /work:
--
--   INSERT INTO public.tasks (work_item_id, stage_id, assignee_id, title, action_type)
--   SELECT w.id, w.current_stage_id,
--          (SELECT id FROM public.users WHERE email = 'drvijayadutta@gmail.com'),
--          w.name, 'COMPLETE_STAGE'
--   FROM public.work_items w
--   WHERE w.source_ref = 'joblist:item:23';
-- ============================================================================
