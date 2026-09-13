-- ============================================================================
-- LOCAL TEST HARNESS ONLY — never applied to Supabase.
--
-- Supabase provides the auth schema, auth.users and auth.uid(). This file
-- recreates just enough of them to run the migrations against a bare Postgres
-- so the DDL and the handoff logic can be proven before they touch a real
-- project.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS extensions;

CREATE TABLE IF NOT EXISTS auth.users (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email               TEXT,
  is_sso_user         BOOLEAN NOT NULL DEFAULT FALSE,
  raw_user_meta_data  JSONB DEFAULT '{}'::jsonb,
  created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Mirrors Supabase's users_email_partial_key. It is a PARTIAL index, so
-- `ON CONFLICT (email)` CANNOT target it and fails with 42P10.
--
-- The shim previously declared a plain UNIQUE here, which let a seed written
-- against it pass locally and then fail on the real project. A test harness
-- that is more permissive than production is worse than no harness: it
-- converts a build error into a deployment error.
CREATE UNIQUE INDEX IF NOT EXISTS users_email_partial_key
  ON auth.users (email) WHERE is_sso_user = FALSE;

-- In Supabase this reads the JWT. Locally we drive it from a session GUC so
-- tests can impersonate a user: SET LOCAL request.jwt.claim.sub = '<uuid>'
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', TRUE), '')::UUID;
$$;

-- Supabase ships these roles; policies reference `authenticated`.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public, auth, extensions TO authenticated, anon, service_role;
