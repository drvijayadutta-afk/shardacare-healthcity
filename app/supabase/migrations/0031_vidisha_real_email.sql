-- ============================================================================
-- 0031_vidisha_real_email.sql — Vidisha's real email address
-- ============================================================================
-- She was one of the 17 people the original job-list import created, seeded
-- under a placeholder address (0011_sharda_team.sql) because the source
-- document gave no contact details. She already holds DESIGNER (0011) and
-- SOCIAL_MEDIA (0028_vidisha_also_social_media.sql, matched on full_name
-- rather than email for exactly this reason — no real email existed yet).
--
-- UNLIKE Anshika (0024_anshika_video_editor.sql), whose placeholder row is
-- created ONLY by 02_seed.sql, Vidisha's placeholder row is created directly
-- by 0011 (schema). That matters: on a from-scratch bootstrap, schema runs
-- entirely before seed (database/SETUP.md's documented order), so the plain
-- rename below would fire immediately within the SAME schema pass that
-- 0011 creates her row in — freeing up 'vidisha@placeholder.invalid' before
-- 02_seed.sql ever runs. Seed's own person insert for that same email would
-- then no longer collide via ON CONFLICT (email), and would create a SECOND,
-- stray 'Vidisha' row. Verified this live: a plain unconditional UPDATE
-- (schema -> seed -> schema again, the project's standard idempotency check)
-- produces two person rows and then a duplicate-key error on the third pass.
--
-- Fixed two ways, both idempotent regardless of run order:
--   1. The UPDATE only fires if no row already holds the real email — so on
--      a later pass, once the canonical row has been renamed, it leaves any
--      stray placeholder row alone instead of colliding with it.
--   2. A follow-up cleanup deletes that stray row once it exists, the same
--      "re-paste 01_schema.sql to heal drift" pattern this project already
--      documents in 00_diagnose.sql. Nothing of substance is lost: a stray
--      row here only ever carries role grants (CREATOR from seed, plus
--      DESIGNER/SOCIAL_MEDIA re-granted by 0011/0028's full_name matching
--      earlier in this same file) — never work data, since 0030 already
--      retired the imported jobs/work items a fresh install would otherwise
--      have linked her to.
--
-- Real effect, not just cosmetic: 0018_daily_digest.sql filters
-- `email NOT LIKE '%@placeholder.invalid'` for both the daily digest
-- recipient list and in-app notifications. She starts receiving both once
-- this runs.
-- ============================================================================

UPDATE public.users
   SET email = 'vidisha.sharma1@shardacare.com'
 WHERE email = 'vidisha@placeholder.invalid'
   AND NOT EXISTS (
     SELECT 1 FROM public.users v WHERE v.email = 'vidisha.sharma1@shardacare.com'
   );

-- Cleanup: remove a stray placeholder row left behind by a later seed run,
-- once the real-email row exists. Guarded against a foreign-key violation
-- (rather than aborting the whole schema apply) in the unlikely case some
-- other data ended up pointing at the stray row — it is then just left in
-- place instead.
DO $$
BEGIN
  DELETE FROM public.users
   WHERE email = 'vidisha@placeholder.invalid'
     AND EXISTS (
       SELECT 1 FROM public.users v WHERE v.email = 'vidisha.sharma1@shardacare.com'
     );
EXCEPTION WHEN foreign_key_violation THEN
  RAISE NOTICE 'A stray vidisha@placeholder.invalid row exists but is still referenced elsewhere -- left in place.';
END $$;
