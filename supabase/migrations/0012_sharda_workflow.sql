-- ============================================================================
-- 0012_sharda_workflow.sql — the process the team actually follows
-- ============================================================================
--   discussion with leadership / doctors
--     -> content (Vijaya)
--     -> creative design (Jaggi / Vivek / Love / Vidisha)
--     -> back to Vijaya, who reviews EVERYTHING
--     -> Sushant or Nirmal
--     -> Parul's final go-ahead
--     -> PO where one is needed
--     -> production -> live
--
-- Every stage points at a ROLE, never a person, so who holds a stage is
-- decided by role assignment in 0011 and changes without touching this file.
-- ============================================================================

-- idx_workflow_templates_one_default permits exactly one default, so the
-- previous holder must be cleared BEFORE this one is inserted -- not after,
-- which is a unique violation.
UPDATE public.workflow_templates SET is_default = FALSE
WHERE is_default AND name <> 'Sharda Marketing Workflow';

INSERT INTO public.workflow_templates (name, description, multi_owner_behavior, is_default)
VALUES (
  'Sharda Marketing Workflow',
  'Leadership brief through to live, with Vijaya reviewing everything and a conditional PO detour.',
  'COLLABORATIVE',
  TRUE
)
ON CONFLICT (name) DO UPDATE
  SET description          = EXCLUDED.description,
      multi_owner_behavior = EXCLUDED.multi_owner_behavior,
      is_default           = TRUE;

-- ----------------------------------------------------------------------------
-- Stages
-- ----------------------------------------------------------------------------
INSERT INTO public.workflow_stages
  (workflow_id, name, stage_order, description,
   requires_approval, requires_attachment, expected_role_id, approval_category, is_terminal)
SELECT w.id, v.name, v.ord, v.descr, v.appr, v.attach,
       (SELECT id FROM public.roles WHERE name = v.role),
       v.cat, v.terminal
FROM public.workflow_templates w,
(VALUES
  ('LEADERSHIP_BRIEF',   1, 'Discussion with leadership or the requesting doctor; scope agreed',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('CONTENT',            2, 'Copy and messaging written',
     FALSE, FALSE, 'CONTENT_WRITER', NULL,         FALSE),
  ('DESIGN',             3, 'Artwork and layout produced',
     FALSE, TRUE,  'DESIGNER',       NULL,         FALSE),
  ('CONTENT_REVIEW',     4, 'Vijaya reviews the finished piece before it goes up the chain',
     FALSE, FALSE, 'CONTENT_WRITER', NULL,         FALSE),
  ('MANAGER_APPROVAL',   5, 'Sushant or Nirmal signs off',
     TRUE,  FALSE, 'APPROVER',       'department', FALSE),
  ('FINAL_APPROVAL',     6, 'Parul gives the final go-ahead',
     TRUE,  FALSE, 'APPROVER',       'final',      FALSE),
  ('PO_REQUEST',         7, 'Purchase order raised with costing',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('PROCUREMENT_REVIEW', 8, 'Vendor and cost checked',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('PO_APPROVAL',        9, 'Purchase order approved',
     TRUE,  FALSE, 'APPROVER',       'po',         FALSE),
  ('PO_RELEASED',       10, 'PO issued to the vendor',
     FALSE, FALSE, 'COORDINATOR',    NULL,         FALSE),
  ('PRODUCTION',        11, 'Printed, produced or built',
     FALSE, TRUE,  'DESIGNER',       NULL,         FALSE),
  ('RELEASE',           12, 'Published and taken live',
     FALSE, FALSE, 'SOCIAL_MEDIA',   NULL,         FALSE),
  ('COMPLETED',         13, 'Closed out',
     FALSE, FALSE, NULL,             NULL,         TRUE)
) AS v(name, ord, descr, appr, attach, role, cat, terminal)
WHERE w.name = 'Sharda Marketing Workflow'
ON CONFLICT (workflow_id, name) DO UPDATE
  SET stage_order         = EXCLUDED.stage_order,
      description         = EXCLUDED.description,
      requires_approval   = EXCLUDED.requires_approval,
      requires_attachment = EXCLUDED.requires_attachment,
      expected_role_id    = EXCLUDED.expected_role_id,
      approval_category   = EXCLUDED.approval_category,
      is_terminal         = EXCLUDED.is_terminal;

-- ----------------------------------------------------------------------------
-- Transitions — the whole routing table
-- ----------------------------------------------------------------------------
WITH w AS (SELECT id FROM public.workflow_templates WHERE name = 'Sharda Marketing Workflow'),
     s AS (SELECT name, id FROM public.workflow_stages WHERE workflow_id = (SELECT id FROM w))
INSERT INTO public.workflow_transitions
  (workflow_id, from_stage_id, to_stage_id, trigger_condition, description)
SELECT (SELECT id FROM w),
       (SELECT id FROM s WHERE s.name = e.from_name),
       (SELECT id FROM s WHERE s.name = e.to_name),
       e.trig, e.descr
FROM (VALUES
  ('LEADERSHIP_BRIEF',   'CONTENT',            'SUBMISSION',       'Brief agreed'),
  ('CONTENT',            'DESIGN',             'SUBMISSION',       'Copy ready'),
  ('DESIGN',             'CONTENT_REVIEW',     'SUBMISSION',       'Design ready for Vijaya'),
  ('CONTENT_REVIEW',     'MANAGER_APPROVAL',   'SUBMISSION',       'Vijaya passed it'),
  ('MANAGER_APPROVAL',   'FINAL_APPROVAL',     'APPROVED',         'Manager signed off'),

  -- Parul's decision forks on whether money needs committing.
  ('FINAL_APPROVAL',     'PO_REQUEST',         'PO_REQUIRED',      'Approved, purchase order needed'),
  ('FINAL_APPROVAL',     'PRODUCTION',         'NO_PO',            'Approved, no purchase order needed'),

  ('PO_REQUEST',         'PROCUREMENT_REVIEW', 'SUBMISSION',       'PO raised'),
  ('PROCUREMENT_REVIEW', 'PO_APPROVAL',        'SUBMISSION',       'Vendor and cost checked'),
  ('PO_APPROVAL',        'PO_RELEASED',        'APPROVED',         'PO approved'),
  ('PO_RELEASED',        'PRODUCTION',         'SUBMISSION',       'PO issued'),

  ('PRODUCTION',         'RELEASE',            'SUBMISSION',       'Produced'),
  ('RELEASE',            'COMPLETED',          'SUBMISSION',       'Live'),

  -- Rejections go back to where the fix happens, not simply one stage back.
  -- All three approval gates sit AFTER design, so the work returns there.
  ('CONTENT_REVIEW',     'DESIGN',             'CHANGES_REQUIRED', 'Vijaya wants changes'),
  ('MANAGER_APPROVAL',   'DESIGN',             'CHANGES_REQUIRED', 'Manager wants changes'),
  ('FINAL_APPROVAL',     'DESIGN',             'CHANGES_REQUIRED', 'Parul wants changes'),
  ('PO_APPROVAL',        'PO_REQUEST',         'CHANGES_REQUIRED', 'PO needs reworking')
) AS e(from_name, to_name, trig, descr)
ON CONFLICT (workflow_id, from_stage_id, trigger_condition) DO UPDATE
  SET to_stage_id = EXCLUDED.to_stage_id,
      description = EXCLUDED.description;

-- No SLAs. No turnaround times were stated, and compute_stage_deadline leaves
-- the deadline NULL rather than inventing one. To add them:
--   INSERT INTO public.stage_sla_config (stage_id, priority, sla_days) ...
