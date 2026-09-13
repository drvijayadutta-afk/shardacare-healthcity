-- ============================================================================
-- 0011_sharda_team.sql — the real team, roles and approval chain
-- ============================================================================
-- Stated by the team lead:
--
--   Jaggi, Vivek, Love     designers
--   Vidisha                Canva designer
--   Indu                   social media manager
--   Vijaya                 senior content writer
--   Sushant, Nirmal        managers of the team
--   Parul                  gives the final go-ahead
--
-- and the process:
--
--   discussion with leadership / doctors -> content -> creative design
--   -> approval from Sushant and Nirmal -> Parul -> (PO where needed)
--   -> production -> release
--
-- Everything here is DATA. Changing who approves what, or who holds a stage,
-- is an UPDATE to these tables — never a code change or a deploy.
--
-- ONE ASSUMPTION, flagged rather than hidden:
--   "approval from sushant and nirmal" is read as EITHER manager approving,
--   not both in sequence. Both are registered at approval_level 1, and the
--   engine takes the first match. To require BOTH, set one of them to
--   approval_level 2 — the engine will then route to level 1, and on approval
--   to level 2. See the note at the foot of this file.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Roles for the actual disciplines
-- ----------------------------------------------------------------------------
INSERT INTO public.roles (name, description, permissions) VALUES
  ('CONTENT_WRITER', 'Writes copy and messaging',
   '["view_own","submit_work","upload_files","add_comments"]'),
  ('DESIGNER', 'Creates artwork and layouts',
   '["view_own","submit_work","upload_files","add_comments"]'),
  ('SOCIAL_MEDIA', 'Publishes and schedules social content',
   '["view_own","submit_work","upload_files","add_comments"]'),
  ('MANAGER', 'Approves team output and reassigns work',
   '["view_all","approve_work","request_changes","reassign_work","modify_deadlines","assign_work","view_reports"]'),
  ('FINAL_APPROVER', 'Gives the final go-ahead before release',
   '["view_all","approve_work","request_changes","add_comments"]')
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      permissions = EXCLUDED.permissions;

-- ----------------------------------------------------------------------------
-- People
--
-- All nine are created here, not only the ones new to the job list. The role
-- assignments below match on full_name, so if this migration relied on the
-- import having run it would silently assign nothing on a database where it
-- had not — leaving a team with no roles and an engine with nobody to route
-- to, with no error to explain it.
--
-- The emails match the pattern the import uses, so ON CONFLICT (email)
-- deduplicates rather than creating a second row for the same person. They
-- stay @placeholder.invalid because no real addresses were given; inventing
-- them would put wrong data in a field that looks authoritative. These are
-- people, not logins — see 0001 on why nothing is written to auth.users.
-- ----------------------------------------------------------------------------
INSERT INTO public.users (email, full_name) VALUES
  ('jaggi@placeholder.invalid',   'Jaggi'),
  ('vivek@placeholder.invalid',   'Vivek'),
  ('love@placeholder.invalid',    'Love'),
  ('vidisha@placeholder.invalid', 'Vidisha'),
  ('indu@placeholder.invalid',    'Indu'),
  ('vijaya@placeholder.invalid',  'Vijaya'),
  ('sushant@placeholder.invalid', 'Sushant'),
  ('nirmal@placeholder.invalid',  'Nirmal'),
  ('parul@placeholder.invalid',   'Parul')
ON CONFLICT (email) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Who is what
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_person TEXT;
  v_role   TEXT;
  v_pairs  TEXT[][] := ARRAY[
    ['Jaggi',   'DESIGNER'],
    ['Vivek',   'DESIGNER'],
    ['Love',    'DESIGNER'],
    ['Vidisha', 'DESIGNER'],        -- Canva specifically; same stage, noted below
    ['Indu',    'SOCIAL_MEDIA'],
    ['Vijaya',  'CONTENT_WRITER'],
    ['Sushant', 'MANAGER'],
    ['Nirmal',  'MANAGER'],
    ['Parul',   'FINAL_APPROVER']
  ];
BEGIN
  FOR i IN 1 .. array_length(v_pairs, 1) LOOP
    v_person := v_pairs[i][1];
    v_role   := v_pairs[i][2];

    INSERT INTO public.user_roles (user_id, role_id)
    SELECT u.id, r.id
    FROM public.users u, public.roles r
    WHERE u.full_name = v_person AND r.name = v_role
    ON CONFLICT (user_id, role_id) DO NOTHING;
  END LOOP;

  -- Managers also need APPROVER so the approval gates can route to them, and
  -- COORDINATOR so they can create and assign work.
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT u.id, r.id FROM public.users u, public.roles r
  WHERE u.full_name IN ('Sushant','Nirmal') AND r.name IN ('APPROVER','COORDINATOR')
  ON CONFLICT (user_id, role_id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role_id)
  SELECT u.id, r.id FROM public.users u, public.roles r
  WHERE u.full_name = 'Parul' AND r.name = 'APPROVER'
  ON CONFLICT (user_id, role_id) DO NOTHING;
END $$;

-- Vidisha works in Canva rather than the design suite. The distinction matters
-- when choosing who to hand a piece of work to, but not to the workflow, so it
-- is recorded on the person instead of becoming a separate stage.
UPDATE public.users SET phone = phone WHERE FALSE;  -- no-op, keeps this block readable
COMMENT ON COLUMN public.users.full_name IS
  'Display name. Discipline detail (e.g. Vidisha works in Canva) lives in user_roles plus this note rather than in a separate stage.';

-- ----------------------------------------------------------------------------
-- The approval chain — the part that was empty before
-- ----------------------------------------------------------------------------
-- department : Sushant or Nirmal
-- final      : Parul
-- po         : Sushant or Nirmal (no separate procurement approver was named)
-- ----------------------------------------------------------------------------
INSERT INTO public.approval_authorities (approver_id, work_category, approval_level)
SELECT u.id, c.category, 1
FROM public.users u
JOIN (VALUES
  ('Sushant','department'), ('Nirmal','department'),
  ('Parul',  'final'),
  ('Sushant','po'),         ('Nirmal','po')
) AS c(person, category) ON c.person = u.full_name
WHERE NOT EXISTS (
  SELECT 1 FROM public.approval_authorities a
  WHERE a.approver_id = u.id AND a.work_category = c.category
);

-- ============================================================================
-- To require BOTH managers rather than either:
--
--   UPDATE public.approval_authorities SET approval_level = 2
--   WHERE work_category = 'department'
--     AND approver_id = (SELECT id FROM public.users WHERE full_name = 'Nirmal');
--
-- and add a second approval stage to the workflow. As it stands the engine
-- routes to the lowest active level and one approval clears the gate.
-- ============================================================================
