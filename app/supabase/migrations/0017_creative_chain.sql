-- ============================================================================
-- 0017_creative_chain.sql — the creative process as the team actually runs it
-- ============================================================================
-- Stated by the team lead:
--
--   "any creative goes through the process of concept creation, copy creation,
--    designer designs it, then Vijaya proofreads it, then Nirmal/Sushant
--    verifies, then Parul verifies"
--
-- Against what 0012 already had, that is two changes, not a rewrite:
--
--   1. CONCEPT CREATION did not exist. Work went straight from the leadership
--      brief to copywriting, so the step where the idea is actually formed had
--      nowhere to live and no owner.
--
--   2. Vijaya's review was a pass-through stage, not a gate. It could only be
--      "submitted", never "approved" or "sent back" — so a proofread that
--      found problems had no way to return the piece to the designer, and the
--      two verifications above it (Sushant/Nirmal, then Parul) were the only
--      real checkpoints. Proofreading is a verification; it is now modelled as
--      one, matching the two steps that follow it.
--
-- Everything else in the chain was already correct: copy -> design ->
-- Vijaya -> managers -> Parul, each pointing at a ROLE, with the approvers
-- resolved from approval_authorities.
--
-- Idempotent. Safe to run twice.
-- ============================================================================

DO $$
DECLARE
  v_workflow UUID;
BEGIN
  SELECT id INTO v_workflow
  FROM public.workflow_templates
  WHERE name = 'Sharda Marketing Workflow';

  IF v_workflow IS NULL THEN
    RAISE NOTICE 'Sharda Marketing Workflow not present — 0012 has not run. Nothing to do.';
    RETURN;
  END IF;

  -- --------------------------------------------------------------------------
  -- stage_order is UNIQUE per workflow, so inserting a stage in the middle
  -- cannot simply renumber in place — the first UPDATE would collide with a
  -- row that has not moved yet. Park everything above the range first.
  -- --------------------------------------------------------------------------
  UPDATE public.workflow_stages
     SET stage_order = stage_order + 100
   WHERE workflow_id = v_workflow;

  -- --------------------------------------------------------------------------
  -- 1. Concept creation
  -- --------------------------------------------------------------------------
  -- Owned by CONTENT_WRITER. The concept is agreed with the team before copy
  -- is written, and Vijaya is the content lead; no separate "concept" role was
  -- named, and inventing one would create a role nobody holds.
  -- --------------------------------------------------------------------------
  INSERT INTO public.workflow_stages
    (workflow_id, name, stage_order, description,
     requires_approval, requires_attachment, expected_role_id,
     approval_category, is_terminal)
  VALUES (
    v_workflow, 'CONCEPT', 2,
    'The idea and angle agreed before any copy is written',
    FALSE, FALSE,
    (SELECT id FROM public.roles WHERE name = 'CONTENT_WRITER'),
    NULL, FALSE
  )
  ON CONFLICT (workflow_id, name) DO UPDATE
    SET stage_order  = EXCLUDED.stage_order,
        description  = EXCLUDED.description;

  -- --------------------------------------------------------------------------
  -- 2. Final ordering of the main track, then the parallel PO track
  -- --------------------------------------------------------------------------
  UPDATE public.workflow_stages s
     SET stage_order = v.ord,
         description = COALESCE(v.descr, s.description)
    FROM (VALUES
      ('LEADERSHIP_BRIEF',   1,  'Discussion with leadership or the requesting doctor; scope agreed'),
      ('CONCEPT',            2,  'The idea and angle agreed before any copy is written'),
      ('CONTENT',            3,  'Copy and messaging written'),
      ('DESIGN',             4,  'Designer produces the artwork'),
      ('CONTENT_REVIEW',     5,  'Vijaya proofreads the finished piece'),
      ('MANAGER_APPROVAL',   6,  'Nirmal or Sushant verifies'),
      ('FINAL_APPROVAL',     7,  'Parul verifies'),
      ('PRODUCTION',         8,  'Printed, produced or built'),
      ('RELEASE',            9,  'Published, posted or put up'),
      ('COMPLETED',         10,  'Closed out'),
      ('PO_REQUEST',        11,  'Purchase order raised with costing'),
      ('PROCUREMENT_REVIEW',12,  'Vendor and cost checked'),
      ('PO_APPROVAL',       13,  'Purchase order approved'),
      ('PO_RELEASED',       14,  'PO issued to the vendor')
    ) AS v(name, ord, descr)
   WHERE s.workflow_id = v_workflow AND s.name = v.name;

  -- Anything this migration does not know about (a stage added by hand) keeps
  -- its relative position rather than colliding at the bottom.
  UPDATE public.workflow_stages
     SET stage_order = stage_order - 80
   WHERE workflow_id = v_workflow AND stage_order > 100;

  -- --------------------------------------------------------------------------
  -- 3. Vijaya's proofread becomes a real verification gate
  -- --------------------------------------------------------------------------
  UPDATE public.workflow_stages
     SET requires_approval = TRUE,
         approval_category = 'proofread'
   WHERE workflow_id = v_workflow AND name = 'CONTENT_REVIEW';

  -- The PO stages belong to the parallel track introduced in 0016. Re-asserted
  -- here because this migration may run on a database where 0016 has already
  -- set it and the UPDATE above rewrote nothing else about them.
  UPDATE public.workflow_stages
     SET track = 'PO'
   WHERE workflow_id = v_workflow
     AND name IN ('PO_REQUEST','PROCUREMENT_REVIEW','PO_APPROVAL','PO_RELEASED');
END $$;


-- ----------------------------------------------------------------------------
-- 4. Vijaya is the proofread approver
-- ----------------------------------------------------------------------------
-- Matched on name like every other authority in 0011, and on the signed-in
-- account's email as well, because the person who logs in as Vijaya may not
-- be the same row as the "Vijaya" the job list imported.
-- ----------------------------------------------------------------------------
INSERT INTO public.approval_authorities (approver_id, work_category, approval_level)
SELECT u.id, 'proofread', 1
FROM public.users u
WHERE (lower(btrim(u.full_name)) = 'vijaya' OR lower(u.email) = 'drvijayadutta@gmail.com')
  AND NOT EXISTS (
    SELECT 1 FROM public.approval_authorities a
    WHERE a.approver_id = u.id AND a.work_category = 'proofread'
  );

-- An approval gate routes to someone holding APPROVER, so Vijaya needs it for
-- the same reason the managers were given it in 0011.
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u, public.roles r
WHERE (lower(btrim(u.full_name)) = 'vijaya' OR lower(u.email) = 'drvijayadutta@gmail.com')
  AND r.name = 'APPROVER'
ON CONFLICT (user_id, role_id) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 5. Routing
-- ----------------------------------------------------------------------------
-- CONTENT_REVIEW's outgoing edge changes trigger: it used to leave on
-- SUBMISSION (a pass-through), and now leaves on APPROVED (a gate). The old
-- edge is deleted rather than left in place — a stale SUBMISSION edge out of
-- an approval stage is exactly the kind of leftover that lets work skip a gate.
-- ----------------------------------------------------------------------------
DELETE FROM public.workflow_transitions t
USING public.workflow_stages s, public.workflow_templates w
WHERE t.from_stage_id = s.id
  AND s.workflow_id = w.id
  AND w.name = 'Sharda Marketing Workflow'
  AND s.name = 'CONTENT_REVIEW'
  AND t.trigger_condition = 'SUBMISSION';

WITH w AS (SELECT id FROM public.workflow_templates WHERE name = 'Sharda Marketing Workflow'),
     s AS (SELECT name, id FROM public.workflow_stages WHERE workflow_id = (SELECT id FROM w))
INSERT INTO public.workflow_transitions
  (workflow_id, from_stage_id, to_stage_id, trigger_condition, description)
SELECT (SELECT id FROM w),
       (SELECT id FROM s WHERE s.name = e.from_name),
       (SELECT id FROM s WHERE s.name = e.to_name),
       e.trig, e.descr
FROM (VALUES
  -- The creative chain, in the order it was described
  ('LEADERSHIP_BRIEF',  'CONCEPT',          'SUBMISSION',       'Brief agreed'),
  ('CONCEPT',           'CONTENT',          'SUBMISSION',       'Concept agreed'),
  ('CONTENT',           'DESIGN',           'SUBMISSION',       'Copy ready'),
  ('DESIGN',            'CONTENT_REVIEW',   'SUBMISSION',       'Design ready for proofreading'),
  ('CONTENT_REVIEW',    'MANAGER_APPROVAL', 'APPROVED',         'Vijaya proofread it'),
  ('MANAGER_APPROVAL',  'FINAL_APPROVAL',   'APPROVED',         'Nirmal or Sushant verified'),

  -- Parul's verification releases the work. Both edges lead to production:
  -- since 0016 the purchase order runs alongside rather than in front.
  ('FINAL_APPROVAL',    'PRODUCTION',       'NO_PO',            'Parul verified'),
  ('FINAL_APPROVAL',    'PRODUCTION',       'PO_REQUIRED',      'Parul verified — PO runs alongside'),

  ('PRODUCTION',        'RELEASE',          'SUBMISSION',       'Produced'),
  ('RELEASE',           'COMPLETED',        'SUBMISSION',       'Live'),

  -- Return paths. Each verification sends the piece back to the desk where the
  -- fixing happens, which is the whole point of naming them separately: a
  -- proofreading error goes to the designer, not back to the brief.
  ('CONTENT_REVIEW',    'DESIGN',           'CHANGES_REQUIRED', 'Vijaya wants changes'),
  ('MANAGER_APPROVAL',  'DESIGN',           'CHANGES_REQUIRED', 'Manager wants changes'),
  ('FINAL_APPROVAL',    'DESIGN',           'CHANGES_REQUIRED', 'Parul wants changes'),
  ('PO_APPROVAL',       'PO_REQUEST',       'CHANGES_REQUIRED', 'PO needs reworking')
) AS e(from_name, to_name, trig, descr)
WHERE (SELECT id FROM s WHERE s.name = e.from_name) IS NOT NULL
  AND (SELECT id FROM s WHERE s.name = e.to_name)   IS NOT NULL
ON CONFLICT (workflow_id, from_stage_id, trigger_condition) DO UPDATE
  SET to_stage_id = EXCLUDED.to_stage_id,
      description = EXCLUDED.description;
