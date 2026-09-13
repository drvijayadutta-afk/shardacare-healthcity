-- ============================================================================
-- 0002_workflow.sql — Configurable workflow definition
-- ============================================================================
-- A workflow is a graph stored as rows:
--   workflow_templates  = the graph
--   workflow_stages     = the nodes
--   workflow_transitions= the edges, each labelled with what triggers it
--   stage_sla_config    = per-stage, per-priority deadline rules
--
-- The handoff engine never branches on a stage NAME. It looks up the edge
-- whose trigger_condition matches what just happened. That is what makes
-- "Approved goes forward, Changes Required goes back, PO required detours"
-- configuration rather than code.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.workflow_templates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  is_default  BOOLEAN NOT NULL DEFAULT FALSE,

  -- Resolves the "multiple people listed" ambiguity in the source data
  -- explicitly, per workflow, instead of the engine guessing per work item.
  multi_owner_behavior TEXT NOT NULL DEFAULT 'SINGLE',

  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_multi_owner CHECK (
    multi_owner_behavior IN ('SINGLE','PARALLEL','SEQUENTIAL','COLLABORATIVE')
  )
);

DROP TRIGGER IF EXISTS trg_workflow_templates_updated_at ON public.workflow_templates;
CREATE TRIGGER trg_workflow_templates_updated_at BEFORE UPDATE ON public.workflow_templates
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Only one template may be the default
CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_templates_one_default
  ON public.workflow_templates(is_default) WHERE is_default;

-- ----------------------------------------------------------------------------
-- workflow_stages — the nodes
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.workflow_stages (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id   UUID NOT NULL REFERENCES public.workflow_templates(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  stage_order   INT  NOT NULL,
  description   TEXT,

  -- Gate behaviour
  requires_approval   BOOLEAN NOT NULL DEFAULT FALSE,
  requires_attachment BOOLEAN NOT NULL DEFAULT FALSE,
  allowed_file_types  JSONB,
  required_fields     JSONB NOT NULL DEFAULT '[]'::jsonb,

  -- Who is expected to hold this stage. A ROLE, never a person.
  expected_role_id    UUID REFERENCES public.roles(id),

  -- Category used to look up approval_authorities when requires_approval.
  -- NULL means "use the job's category".
  approval_category   TEXT,

  -- Fallback SLA. stage_sla_config overrides per priority.
  -- NULL means "no SLA configured" -> the engine leaves the deadline NULL
  -- rather than inventing one.
  sla_days      INT,

  is_terminal   BOOLEAN NOT NULL DEFAULT FALSE,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (workflow_id, stage_order),
  UNIQUE (workflow_id, name)
);

CREATE INDEX IF NOT EXISTS idx_workflow_stages_workflow
  ON public.workflow_stages(workflow_id, stage_order);

-- ----------------------------------------------------------------------------
-- workflow_transitions — the edges
--
-- trigger_condition values are workflow vocabulary, not business rules:
--   SUBMISSION        - owner clicked Submit for Next Stage
--   APPROVED          - approver approved
--   CHANGES_REQUIRED  - approver sent it back
--   REJECTED          - approver killed it
--   PO_REQUIRED       - taken when work_items.po_required = true
--   NO_PO             - taken when work_items.po_required = false
--   PO_RELEASED       - procurement released the PO
--   VENDOR_COMPLETE   - external vendor delivered
--
-- to_stage_id NULL = workflow ends here.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.workflow_transitions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id       UUID NOT NULL REFERENCES public.workflow_templates(id) ON DELETE CASCADE,
  from_stage_id     UUID NOT NULL REFERENCES public.workflow_stages(id) ON DELETE CASCADE,
  to_stage_id       UUID REFERENCES public.workflow_stages(id) ON DELETE CASCADE,
  trigger_condition TEXT NOT NULL,
  description       TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (workflow_id, from_stage_id, trigger_condition),
  CONSTRAINT chk_trigger_condition CHECK (trigger_condition IN (
    'SUBMISSION','APPROVED','CHANGES_REQUIRED','REJECTED',
    'PO_REQUIRED','NO_PO','PO_RELEASED','VENDOR_COMPLETE'
  ))
);

CREATE INDEX IF NOT EXISTS idx_workflow_transitions_lookup
  ON public.workflow_transitions(from_stage_id, trigger_condition)
  WHERE is_active;

-- ----------------------------------------------------------------------------
-- stage_sla_config — deadlines as data, per stage and priority
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stage_sla_config (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stage_id   UUID NOT NULL REFERENCES public.workflow_stages(id) ON DELETE CASCADE,
  priority   TEXT NOT NULL,
  sla_days   INT  NOT NULL CHECK (sla_days >= 0),
  escalate_after_days INT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (stage_id, priority),
  CONSTRAINT chk_sla_priority CHECK (priority IN ('CRITICAL','HIGH','MEDIUM','LOW'))
);

CREATE INDEX IF NOT EXISTS idx_stage_sla_stage ON public.stage_sla_config(stage_id);
