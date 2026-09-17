-- ============================================================================
-- 0028_vidisha_also_social_media.sql — Vidisha also holds SOCIAL_MEDIA
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Additive: Vidisha (from 0011, "Canva designer", DESIGNER only) also gets
-- SOCIAL_MEDIA, alongside her existing role rather than in place of it.
--
-- Matched on full_name = 'Vidisha', mirroring 0011's own DO block for the
-- same person, because -- unlike Anshika (0024, given a real email) --
-- Vidisha has no real email yet: she's still vidisha@placeholder.invalid.
--
-- Practical effect: the RELEASE stage's expected_role_id is SOCIAL_MEDIA
-- (0012: "Indu posts it on social media"), so she becomes eligible for its
-- auto-assignment; and shows up under "Social media" in TeamRoster.tsx's
-- role grouping in addition to "Designer" -- no app code changes needed, it
-- groups by whatever roles a person actually holds.
-- ============================================================================

INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE u.full_name = 'Vidisha' AND r.name = 'SOCIAL_MEDIA'
ON CONFLICT (user_id, role_id) DO NOTHING;
