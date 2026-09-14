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

-- ============================================================================
-- Minimal Storage stand-in.
--
-- Supabase Storage provides storage.buckets, storage.objects and
-- storage.foldername() automatically. This reproduces only the columns and
-- function 0015_attachments_tags_status_control.sql's bucket insert and
-- policies actually touch — enough to prove the RLS is correct, not a general
-- Storage emulator.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 TEXT PRIMARY KEY,
  name               TEXT NOT NULL,
  owner              UUID,
  public             BOOLEAN DEFAULT FALSE,
  file_size_limit    BIGINT,
  allowed_mime_types TEXT[],
  created_at         TIMESTAMPTZ DEFAULT NOW(),
  updated_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id  TEXT REFERENCES storage.buckets(id),
  name       TEXT,
  owner      UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  metadata   JSONB
);

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Real Supabase splits the object path on '/' and returns every segment
-- except the last (the filename). Object names here are laid out as
-- '<work_item_id>/<uuid>-<filename>', so [1] is the work item id.
CREATE OR REPLACE FUNCTION storage.foldername(name TEXT)
RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
  SELECT (regexp_split_to_array(name, '/'))[1 : array_length(regexp_split_to_array(name, '/'), 1) - 1];
$$;

GRANT USAGE ON SCHEMA storage TO authenticated, anon, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated, service_role;
GRANT SELECT ON storage.buckets TO authenticated, anon, service_role;
GRANT ALL ON storage.buckets TO service_role;
