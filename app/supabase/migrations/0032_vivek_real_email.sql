-- ============================================================================
-- 0032_vivek_real_email.sql — Vivek's real email address
-- ============================================================================
-- He is one of the 9 real team members created directly in schema
-- (0011_sharda_team.sql), seeded under a placeholder address because no real
-- one was given at the time. He already holds DESIGNER (0011).
--
-- Same category as Vidisha (0031_vidisha_real_email.sql), not Anshika
-- (0024_anshika_video_editor.sql): his placeholder row is created by SCHEMA
-- (0011), not only by 02_seed.sql. That matters on a from-scratch bootstrap,
-- where schema runs entirely before seed (database/SETUP.md's documented
-- order) — a plain, unconditional rename would fire within the same schema
-- pass that creates his row, freeing up 'vivek@placeholder.invalid' before
-- seed's own insert for that email ever runs, so seed's ON CONFLICT (email)
-- no longer catches it and creates a second, stray 'Vivek' row. This is
-- exactly the bug 0031 found and fixed live (three-pass idempotency test:
-- schema -> seed -> schema again produced two rows, then a duplicate-key
-- error on a third pass) — same fix applied here unchanged.
--
--   1. The UPDATE only fires if no row already holds the real email — so on
--      a later pass, once the canonical row has been renamed, it leaves any
--      stray placeholder row alone instead of colliding with it.
--   2. A follow-up cleanup deletes that stray row once it exists (same
--      "re-paste 01_schema.sql to heal drift" pattern this project already
--      documents in 00_diagnose.sql). Nothing of substance is lost: a stray
--      row here only ever carries role grants (CREATOR from seed, plus
--      DESIGNER re-granted by 0011's full_name matching earlier in this same
--      file) — never work data, since 0030 already retired the imported
--      jobs/work items a fresh install would otherwise have linked him to.
--
-- Real effect, not just cosmetic: 0018_daily_digest.sql filters
-- `email NOT LIKE '%@placeholder.invalid'` for both the daily digest
-- recipient list and in-app notifications. He starts receiving both once
-- this runs.
-- ============================================================================

UPDATE public.users
   SET email = 'Vivekanand.mehra@shardacare.com'
 WHERE email = 'vivek@placeholder.invalid'
   AND NOT EXISTS (
     SELECT 1 FROM public.users v WHERE v.email = 'Vivekanand.mehra@shardacare.com'
   );

DO $$
BEGIN
  DELETE FROM public.users
   WHERE email = 'vivek@placeholder.invalid'
     AND EXISTS (
       SELECT 1 FROM public.users v WHERE v.email = 'Vivekanand.mehra@shardacare.com'
     );
EXCEPTION WHEN foreign_key_violation THEN
  RAISE NOTICE 'A stray vivek@placeholder.invalid row exists but is still referenced elsewhere -- left in place.';
END $$;
