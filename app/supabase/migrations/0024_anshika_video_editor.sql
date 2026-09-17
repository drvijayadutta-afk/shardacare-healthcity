-- ============================================================================
-- 0024_anshika_video_editor.sql — Anshika, properly set up
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Anshika already exists in the seeded data (database/supabase-bundle/02_seed.sql
-- inserted her as anshika@placeholder.invalid / 'Anshika' -- she's the
-- owner/collaborator on "ShardaCare hai na film", fittingly a video job --
-- because the imported job list named her but gave no contact details. Like
-- all 17 imported people she only holds the blanket bootstrap CREATOR role;
-- per database/SETUP.md that exists only "so RLS can be tested; reassign
-- properly before real use."
--
-- This gives her the real discipline (video editor) and her real official
-- email in place of the placeholder.
--
-- NOTE: a real email takes her out of 0018_daily_digest.sql's
-- `WHERE u.email NOT LIKE '%@placeholder.invalid'` filter on both the daily
-- digest recipient list and in-app notifications -- she starts receiving
-- those. That's the point of giving her a real address, not a side effect
-- to work around.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Role for the discipline. Mirrors DESIGNER's permission set exactly (which
-- is also CREATOR's -- this is a discipline label for routing/display, not a
-- change in what she's allowed to do).
-- ----------------------------------------------------------------------------
INSERT INTO public.roles (name, description, permissions) VALUES
  ('VIDEO_EDITOR', 'Edits and produces video content',
   '["view_own","submit_work","upload_files","add_comments"]')
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      permissions = EXCLUDED.permissions;

-- ----------------------------------------------------------------------------
-- Her person row. Two cases:
--   1. A row already has the real email (this migration ran before, or ran
--      after the placeholder was already renamed) -> no-op.
--   2. The placeholder row from the import exists -> UPDATE it in place, so
--      her user id -- and the FK references from her two existing imported
--      work items -- stay intact.
--
-- Deliberately does NOT insert her fresh when neither row exists yet (e.g. a
-- from-scratch bootstrap where migrations run before 02_seed.sql, per
-- database/SETUP.md's own documented order). Tested that path directly:
-- inserting a fresh row here, then letting 02_seed.sql run afterward and
-- insert ITS OWN anshika@placeholder.invalid row (a different email, so
-- ON CONFLICT (email) does not catch it), produces two people -- and the
-- imported work item's owner_id ends up on the wrong one, since the import
-- links by the placeholder email, not the real one. Skipping cleanly here
-- instead means: on that path, re-running this same bundle a second time
-- (the standard fix this project already tells you to do all over
-- 00_diagnose.sql -- "re-paste and re-run 01_schema.sql") finds the
-- placeholder row seed created and updates it correctly, with no duplicate
-- ever created.
-- ----------------------------------------------------------------------------
UPDATE public.users
   SET email = 'anshika.pundhir@shardacare.com',
       full_name = 'Anshika Pundhir'
 WHERE email = 'anshika@placeholder.invalid';

-- ----------------------------------------------------------------------------
-- Grant the real role, drop the bootstrap one -- matching what every one of
-- 0011's nine real team members ended up with (one discipline role, not
-- CREATOR-plus-discipline). No access is lost: identical permission set.
-- ----------------------------------------------------------------------------
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE u.email = 'anshika.pundhir@shardacare.com' AND r.name = 'VIDEO_EDITOR'
ON CONFLICT (user_id, role_id) DO NOTHING;

DELETE FROM public.user_roles ur
USING public.users u, public.roles r
WHERE ur.user_id = u.id AND ur.role_id = r.id
  AND u.email = 'anshika.pundhir@shardacare.com' AND r.name = 'CREATOR';
