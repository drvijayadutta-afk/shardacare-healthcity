-- ============================================================================
-- 0033_anjali_designer.sql — Anjali joins the design team
-- ============================================================================
-- Stated by the team lead: the Design stage is held by Love, Vivek, Jaggi,
-- Vidisha, Anjali and Anshika. The first five and Anshika were already in the
-- system (0011_sharda_team.sql; Anshika via 0024/0027) — Anjali is new,
-- named here for the first time.
--
-- Unlike Anshika (0024_anshika_video_editor.sql), there is no existing
-- placeholder row to rename: she was never mentioned in the imported 10th
-- Sept job list, so there is nothing to relink. A fresh row is created
-- outright, same as the nine people in 0011.
--
-- Idempotent. Safe to run twice.
-- ============================================================================

INSERT INTO public.users (email, full_name)
VALUES ('anjali@placeholder.invalid', 'Anjali')
ON CONFLICT (email) DO NOTHING;

-- Same discipline as Love, Vivek, Jaggi, Vidisha and Anshika: eligible for the
-- DESIGN stage's auto-assignment (workflow_stages.expected_role_id for
-- DESIGN -> DESIGNER; resolve_next_assignee() picks from work_item_owners
-- holding that role) and grouped under "Designer" in TeamRoster.tsx.
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE u.email = 'anjali@placeholder.invalid' AND r.name = 'DESIGNER'
ON CONFLICT (user_id, role_id) DO NOTHING;

-- ============================================================================
-- She has no real email yet (like Jaggi and Love). When one is given, follow
-- the pattern in 0031_vidisha_real_email.sql / 0032_vivek_real_email.sql:
--
--   UPDATE public.users SET email = '<her real address>'
--   WHERE email = 'anjali@placeholder.invalid';
--
-- That also takes her out of 0018_daily_digest.sql's
-- `email NOT LIKE '%@placeholder.invalid'` filter, so she starts receiving
-- the daily digest and in-app notifications.
-- ============================================================================
