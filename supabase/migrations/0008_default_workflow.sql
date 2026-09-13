-- ============================================================================
-- 0008_default_workflow.sql — the standard workflow, as configuration
-- ============================================================================
-- Built from the stated flow:
--
--   Request -> Brief -> Content -> Design -> Internal Review ->
--   Department Approval -> [Procurement/PO] -> Production ->
--   Final Approval -> Release -> Completed
--
-- and the stated PO rule:
--
--   PO Required = No   : Department Approval -> Production
--   PO Required = Yes  : Department Approval -> PO Request ->
--                        Procurement Review -> PO Approval ->
--                        PO Released -> Production
--
-- WHAT THIS FILE DOES NOT DO, deliberately:
--
--   * No SLAs. sla_days is left NULL on every stage, so the engine sets no
--     deadline rather than inventing one. Suggested durations are in the
--     separate, optional 04_sla_suggested.sql — they are a proposal, not
--     something the source material specified.
--   * No approvers. approval_authorities stays empty. Until rows are added,
--     work reaching an approval stage parks as 'unassigned' and shows up on
--     the Control Tower, which is the correct visible failure rather than a
--     silent assignment to an arbitrary person.
--   * No people. Nothing here names anyone.
-- ============================================================================

INSERT INTO public.workflow_templates (name, description, multi_owner_behavior, is_default)
VALUES (
  'Standard Marketing Workflow',
  'Request through Release, with a conditional procurement detour.',
  'COLLABORATIVE',
  TRUE
)
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      multi_owner_behavior = EXCLUDED.multi_owner_behavior;

-- ----------------------------------------------------------------------------
-- Stages
--
-- expected_role_id maps a stage to a ROLE, never a person, so who actually
-- holds a stage is decided by role assignment at runtime.
-- ----------------------------------------------------------------------------
INSERT INTO public.workflow_stages
  (workflow_id, name, stage_order, description,
   requires_approval, requires_attachment, expected_role_id,
   approval_category, is_terminal)
SELECT
  w.id, v.name, v.ord, v.descr, v.appr, v.attach,
  (SELECT id FROM public.roles WHERE name = v.role),
  v.cat, v.terminal
FROM public.workflow_templates w,
(VALUES
  ('REQUEST',              1,  'Request raised and scoped',
     FALSE, FALSE, 'REQUESTOR',        NULL,        FALSE),
  ('BRIEF',                2,  'Requirements clarified, creator assigned',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('CONTENT',              3,  'Copy and messaging written',
     FALSE, FALSE, 'CREATOR',          NULL,        FALSE),
  ('DESIGN',               4,  'Visual or layout produced',
     FALSE, TRUE,  'CREATOR',          NULL,        FALSE),
  ('INTERNAL_REVIEW',      5,  'Internal QA and brand check',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('DEPARTMENT_APPROVAL',  6,  'Formal departmental sign-off',
     TRUE,  FALSE, 'APPROVER',         'department',FALSE),
  ('PO_REQUEST',           7,  'Purchase order raised with costing',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('PROCUREMENT_REVIEW',   8,  'Procurement checks vendor and cost',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('PO_APPROVAL',          9,  'Purchase order approved',
     TRUE,  FALSE, 'APPROVER',         'po',        FALSE),
  ('PO_RELEASED',         10,  'Purchase order issued to the vendor',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('PRODUCTION',          11,  'Approved work produced or printed',
     FALSE, TRUE,  'VENDOR',           NULL,        FALSE),
  ('FINAL_APPROVAL',      12,  'Sign-off on the finished deliverable',
     TRUE,  FALSE, 'APPROVER',         'final',     FALSE),
  ('RELEASE',             13,  'Published, printed or sent live',
     FALSE, FALSE, 'COORDINATOR',      NULL,        FALSE),
  ('COMPLETED',           14,  'Closed out',
     FALSE, FALSE, NULL,               NULL,        TRUE)
) AS v(name, ord, descr, appr, attach, role, cat, terminal)
WHERE w.name = 'Standard Marketing Workflow'
ON CONFLICT (workflow_id, name) DO UPDATE
  SET stage_order         = EXCLUDED.stage_order,
      description         = EXCLUDED.description,
      requires_approval   = EXCLUDED.requires_approval,
      requires_attachment = EXCLUDED.requires_attachment,
      expected_role_id    = EXCLUDED.expected_role_id,
      approval_category   = EXCLUDED.approval_category,
      is_terminal         = EXCLUDED.is_terminal;

-- ----------------------------------------------------------------------------
-- Transitions — the edges that make the flow configurable
--
-- Read this block as the whole routing table. Changing how work moves means
-- editing rows here; it never means changing application code.
-- ----------------------------------------------------------------------------
WITH w AS (SELECT id FROM public.workflow_templates WHERE name = 'Standard Marketing Workflow'),
     s AS (SELECT name, id FROM public.workflow_stages
           WHERE workflow_id = (SELECT id FROM w))
INSERT INTO public.workflow_transitions
  (workflow_id, from_stage_id, to_stage_id, trigger_condition, description)
SELECT (SELECT id FROM w),
       (SELECT id FROM s WHERE s.name = e.from_name),
       (SELECT id FROM s WHERE s.name = e.to_name),
       e.trig, e.descr
FROM (VALUES
  -- Forward path
  ('REQUEST',             'BRIEF',              'SUBMISSION',       'Request accepted'),
  ('BRIEF',               'CONTENT',            'SUBMISSION',       'Brief agreed'),
  ('CONTENT',             'DESIGN',             'SUBMISSION',       'Copy ready'),
  ('DESIGN',              'INTERNAL_REVIEW',    'SUBMISSION',       'Design ready for QA'),
  ('INTERNAL_REVIEW',     'DEPARTMENT_APPROVAL','SUBMISSION',       'Passed internal review'),

  -- The PO fork. Both edges leave the same stage; work_items.po_required
  -- decides which one is taken.
  ('DEPARTMENT_APPROVAL', 'PO_REQUEST',         'PO_REQUIRED',      'Approved, procurement needed'),
  ('DEPARTMENT_APPROVAL', 'PRODUCTION',         'NO_PO',            'Approved, no procurement needed'),

  -- Procurement detour
  ('PO_REQUEST',          'PROCUREMENT_REVIEW', 'SUBMISSION',       'PO raised'),
  ('PROCUREMENT_REVIEW',  'PO_APPROVAL',        'SUBMISSION',       'Procurement checked'),
  ('PO_APPROVAL',         'PO_RELEASED',        'APPROVED',         'PO approved'),
  ('PO_RELEASED',         'PRODUCTION',         'SUBMISSION',       'PO issued to vendor'),

  -- Tail
  ('PRODUCTION',          'FINAL_APPROVAL',     'SUBMISSION',       'Production complete'),
  ('FINAL_APPROVAL',      'RELEASE',            'APPROVED',         'Final sign-off given'),
  ('RELEASE',             'COMPLETED',          'SUBMISSION',       'Live'),

  -- Return paths. Each approval gate sends work back to where the fixing
  -- happens, which is what makes "Changes Required" land on the right desk
  -- rather than simply one stage back.
  ('INTERNAL_REVIEW',     'DESIGN',             'CHANGES_REQUIRED', 'QA found problems'),
  ('DEPARTMENT_APPROVAL', 'DESIGN',             'CHANGES_REQUIRED', 'Approver wants changes'),
  ('PO_APPROVAL',         'PO_REQUEST',         'CHANGES_REQUIRED', 'PO needs reworking'),
  ('FINAL_APPROVAL',      'PRODUCTION',         'CHANGES_REQUIRED', 'Final check failed')
) AS e(from_name, to_name, trig, descr)
ON CONFLICT (workflow_id, from_stage_id, trigger_condition) DO UPDATE
  SET to_stage_id = EXCLUDED.to_stage_id,
      description = EXCLUDED.description;

-- ----------------------------------------------------------------------------
-- Deliberately empty: approval_authorities
--
-- Nothing is inserted here because who approves what was never stated. The
-- rows needed look like this — fill in real user ids and run:
--
--   INSERT INTO public.approval_authorities
--     (approver_id, work_category, approval_level, amount_min, amount_max)
--   VALUES
--     ('<user uuid>', 'department', 1, 0, NULL),
--     ('<user uuid>', 'po',         1, 0, 50000),
--     ('<user uuid>', 'po',         2, 50001, NULL),
--     ('<user uuid>', 'final',      1, 0, NULL);
--
-- work_category matches workflow_stages.approval_category above:
-- 'department', 'po' and 'final'. Until at least one row exists per category,
-- work arriving at that gate is parked as unassigned and surfaces on the
-- Control Tower as needing an owner.
-- ----------------------------------------------------------------------------
