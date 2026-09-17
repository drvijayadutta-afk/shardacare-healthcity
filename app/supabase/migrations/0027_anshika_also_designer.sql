-- ============================================================================
-- 0027_anshika_also_designer.sql — Anshika also holds DESIGNER
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Additive: Anshika (anshika.pundhir@shardacare.com, VIDEO_EDITOR since 0024)
-- also gets DESIGNER, alongside her existing role rather than in place of it.
-- Matched on her real email, not full_name, for the same reason as 0024 --
-- avoids any ambiguity if another person ever shares a first name.
--
-- Practical effect: she becomes eligible for the DESIGN stage's
-- auto-assignment (workflow_stages.expected_role_id for DESIGN -> DESIGNER;
-- resolve_next_assignee() picks from work_item_owners holding that role),
-- and shows up under "Designer" in TeamRoster.tsx's role grouping in
-- addition to "Video editor" -- no app code changes needed, it groups by
-- whatever roles a person actually holds.
-- ============================================================================

INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE u.email = 'anshika.pundhir@shardacare.com' AND r.name = 'DESIGNER'
ON CONFLICT (user_id, role_id) DO NOTHING;
