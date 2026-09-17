-- ============================================================================
-- 0029_vijaya_content_writer.sql — Vijaya (drvijayadutta@gmail.com) also
--   holds CONTENT_WRITER
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- 0017_creative_chain.sql already matched this exact identity --
--   lower(full_name) = 'vijaya' OR lower(email) = 'drvijayadutta@gmail.com'
-- -- to grant the proofread-APPROVER role, with its own comment noting "the
-- person who logs in as Vijaya may not be the same row as the 'Vijaya' the
-- job list imported." That block only granted APPROVER (the proofread
-- gate); it never granted CONTENT_WRITER, which is what the CONCEPT and
-- CONTENT stages actually route to (0012/0017: deliberately the same role
-- for both -- "no separate 'concept' role was named, and inventing one
-- would create a role nobody holds"). So the account could approve/
-- proofread, but was never eligible for the Content picker on New Work, or
-- for CONCEPT/CONTENT/CONTENT_REVIEW stage auto-assignment -- same "missing
-- from the dropdown" symptom as Vidisha's case (0028), a different role.
--
-- Reuses 0017's matching expression verbatim, not a new convention.
-- ============================================================================

INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE (lower(btrim(u.full_name)) = 'vijaya' OR lower(u.email) = 'drvijayadutta@gmail.com')
  AND r.name = 'CONTENT_WRITER'
ON CONFLICT (user_id, role_id) DO NOTHING;
