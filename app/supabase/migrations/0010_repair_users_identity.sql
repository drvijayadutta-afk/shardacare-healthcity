-- ============================================================================
-- 0010_repair_users_identity.sql — bring an EXISTING database up to date
-- ============================================================================
-- 0001 defines public.users with `CREATE TABLE IF NOT EXISTS`, which creates
-- the table correctly on a fresh database and does NOTHING on one that already
-- has it. So the change in 0001 that removed the foreign key to auth.users and
-- gave `id` its own default never reached any database created before that
-- change: re-running the schema looked successful and altered nothing.
--
-- The visible symptom was the seed failing with
--   null value in column "id" of relation "users" violates not-null constraint
-- and, because the seed aborted, an application with no data in it at all.
--
-- This file performs the same change as an ALTER, so it converges an old
-- database on the current shape. It is a no-op on a new one.
-- ============================================================================

-- `id` must generate its own value: people imported from the job list are not
-- login accounts and have no auth.users row to take an id from.
ALTER TABLE public.users ALTER COLUMN id SET DEFAULT gen_random_uuid();

-- Drop the foreign key to auth.users if this database still carries it.
-- Looked up by catalog rather than by name because the name was never
-- specified explicitly and Postgres generated it.
DO $$
DECLARE
  v_constraint TEXT;
BEGIN
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.users'::regclass
    AND contype  = 'f'
    AND confrelid = 'auth.users'::regclass
  LIMIT 1;

  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.users DROP CONSTRAINT %I', v_constraint);
    RAISE NOTICE 'Dropped % — public.users no longer requires an auth account.', v_constraint;
  END IF;
END $$;
