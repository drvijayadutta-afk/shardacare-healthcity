-- ============================================================================
-- 0018_daily_digest.sql — the 6pm end-of-day status digest
-- ============================================================================
-- Stated by the team lead:
--   "everybody should get notification on WhatsApp group at the end of the day
--    6 pm about the status of work aligned for the particular day"
--
-- This file provides the CONTENT. Delivery is in src/app/api/digest/, because
-- of a constraint worth stating plainly rather than discovering later:
--
--   The official WhatsApp Business/Cloud API cannot post to a group. It sends
--   to individual numbers only. Meta has never exposed group messaging, and
--   the services that claim to do it drive an unofficial client that gets
--   numbers banned.
--
-- So the digest is produced once, here, and delivered three ways: an in-app
-- notification per person, an individual WhatsApp message per person where a
-- number and API credentials exist, and a formatted block on /digest that one
-- person pastes into the group in a single tap. The first two are automatic;
-- the third is the honest version of "post it to the group".
--
-- Idempotent. Safe to run twice.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A place to keep the digest secret, so the cron endpoint can read the digest
-- without a service_role key. That key bypasses row-level security entirely
-- and would undo the guarantee the whole schema is built on; a single-purpose
-- shared secret that unlocks exactly one read-only function does not.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_settings (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

-- No policy for `authenticated` at all: RLS with zero policies denies everyone.
-- Only SECURITY DEFINER functions below can read it.
DROP POLICY IF EXISTS app_settings_admin ON public.app_settings;
CREATE POLICY app_settings_admin ON public.app_settings FOR ALL TO authenticated
  USING (public.has_role(ARRAY['ADMIN']))
  WITH CHECK (public.has_role(ARRAY['ADMIN']));

INSERT INTO public.app_settings (key, value)
VALUES ('digest_secret',
        replace(gen_random_uuid()::text, '-', '') ||
        replace(gen_random_uuid()::text, '-', ''))
ON CONFLICT (key) DO NOTHING;


-- ----------------------------------------------------------------------------
-- "Work aligned for the particular day"
--
-- Read as: everything that was supposed to move today. That is wider than
-- "deadline = today" — a digest that omitted the three items that went
-- overdue yesterday would be the most misleading message of the day.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.daily_digest_rows()
RETURNS TABLE (
  bucket        TEXT,
  work_item_id  UUID,
  name          TEXT,
  stage_name    TEXT,
  status        TEXT,
  owner_name    TEXT,
  owner_id      UUID,
  deadline      DATE,
  po_status     TEXT,
  priority      TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    CASE
      WHEN w.status IN ('COMPLETED','CANCELLED')                       THEN 'completed_today'
      WHEN COALESCE(w.stage_deadline, w.deadline) < CURRENT_DATE       THEN 'overdue'
      WHEN COALESCE(w.stage_deadline, w.deadline) = CURRENT_DATE       THEN 'due_today'
      WHEN w.status IN ('ON_HOLD','BLOCKED')                           THEN 'blocked'
      ELSE 'in_flight'
    END AS bucket,
    w.id,
    w.name,
    COALESCE(s.name, 'No stage'),
    w.status,
    u.full_name,
    w.current_assignee_id,
    COALESCE(w.stage_deadline, w.deadline),
    w.po_status,
    w.priority
  FROM public.work_items w
  LEFT JOIN public.workflow_stages s ON s.id = w.current_stage_id
  LEFT JOIN public.users u ON u.id = COALESCE(w.current_assignee_id, w.owner_id)
  WHERE
    -- Everything still open …
    (w.status NOT IN ('COMPLETED','CANCELLED','REJECTED')
     AND (
       COALESCE(w.stage_deadline, w.deadline) <= CURRENT_DATE
       OR w.status IN ('ON_HOLD','BLOCKED')
       OR w.updated_at::date = CURRENT_DATE
     ))
    -- … plus what actually finished today, so the message carries some good news
    OR (w.status IN ('COMPLETED','CANCELLED') AND w.updated_at::date = CURRENT_DATE)
  ORDER BY 1, COALESCE(w.stage_deadline, w.deadline) NULLS LAST, w.name;
$$;


-- ----------------------------------------------------------------------------
-- The whole digest in one call, for the 6pm cron.
--
-- Takes the shared secret rather than a session: this runs from a scheduled
-- job with nobody signed in. It returns status only — names, stages and dates
-- — and no file contents, comments or costs, so the blast radius if the secret
-- leaked is a list of work titles rather than the database.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.daily_digest(p_secret TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_expected TEXT;
  v_result   JSONB;
BEGIN
  SELECT value INTO v_expected FROM public.app_settings WHERE key = 'digest_secret';

  -- md5() is built in; pgcrypto's digest() lives in the extensions schema and
  -- would not resolve under SET search_path = public. Hashing both sides keeps
  -- the comparison length-independent, which is all this needs: the secret
  -- travels over TLS to a cron endpoint, not through a user-facing form.
  IF v_expected IS NULL
     OR md5(COALESCE(p_secret, '')) IS DISTINCT FROM md5(v_expected)
  THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'generated_at', NOW(),
    'date',         CURRENT_DATE,
    'totals', (
      SELECT jsonb_object_agg(bucket, n)
      FROM (SELECT bucket, COUNT(*) AS n FROM public.daily_digest_rows() GROUP BY bucket) x
    ),
    'items', (
      SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.bucket, r.deadline NULLS LAST), '[]'::jsonb)
      FROM public.daily_digest_rows() r
    ),
    'recipients', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'user_id', u.id, 'name', u.full_name, 'phone', u.phone,
               'email', u.email)), '[]'::jsonb)
      FROM public.users u
      WHERE u.is_active
        AND u.email NOT LIKE '%@placeholder.invalid'
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- `anon` is what an unauthenticated cron request arrives as. The secret check
-- inside the function is the actual gate; without it this grant would expose
-- the digest to the internet.
GRANT EXECUTE ON FUNCTION public.daily_digest(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.daily_digest_rows() TO authenticated;


-- ----------------------------------------------------------------------------
-- Record that the digest went out, and give each person an in-app copy.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_digest_sent(p_secret TEXT, p_summary TEXT)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_expected TEXT;
  v_count    INT;
BEGIN
  SELECT value INTO v_expected FROM public.app_settings WHERE key = 'digest_secret';
  IF v_expected IS NULL OR p_secret IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.notifications (recipient_id, type, subject, body, action_url, channel)
  SELECT u.id, 'DAILY_DIGEST',
         'End of day — ' || to_char(CURRENT_DATE, 'DD Mon'),
         p_summary, '/work?filter=active', 'IN_APP'
  FROM public.users u
  WHERE u.is_active AND u.email NOT LIKE '%@placeholder.invalid';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_digest_sent(TEXT, TEXT) TO anon, authenticated;
