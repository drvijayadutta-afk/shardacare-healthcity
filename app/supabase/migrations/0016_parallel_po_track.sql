-- ============================================================================
-- 0016_parallel_po_track.sql — procurement runs ALONGSIDE the work, not in
--                              front of it
-- ============================================================================
-- Stated by the team lead:
--   "all PO related tasks should be aligned simultaneously and make it easy
--    to follow"
--
-- WHAT WAS WRONG
--
-- 0008 modelled procurement as a detour on the critical path:
--
--   Department Approval -> PO Request -> Procurement Review -> PO Approval
--                       -> PO Released -> Production -> ...
--
-- So a hoarding whose artwork was signed off on Monday could not START
-- production until a purchase order had been raised, reviewed, approved and
-- issued. Four stages of waiting, during which the work item showed a
-- procurement stage as its status and the creative team had nothing to look at.
-- Every PO item was structurally late.
--
-- WHAT THIS CHANGES
--
-- Procurement becomes a SECOND TRACK that opens the moment departmental
-- approval is given, and runs at the same time as production:
--
--   main track :  Department Approval -> Production -> Final Approval -> Release
--   PO track   :  Requested -> In Review -> Approved -> Released
--                 (opens automatically, at the same moment)
--
-- The real constraint is kept, and only the real one: work cannot go LIVE
-- before the PO is released. Everything up to that point proceeds in parallel.
-- That is enforced at the bottom of this file, with a message that says what
-- is missing rather than silently refusing.
--
-- Idempotent. Safe to run twice.
-- ============================================================================


-- ============================================================================
-- 1. Take procurement off the critical path
-- ============================================================================
-- The fork out of DEPARTMENT_APPROVAL had two edges. Both now lead to
-- PRODUCTION; what po_required decides is no longer WHERE the work goes, but
-- whether a PO track is opened beside it.
--
-- resolve_submit_trigger() still returns 'PO_REQUIRED' / 'NO_PO' and needs no
-- change — the edge it names simply has a different destination now.
-- ----------------------------------------------------------------------------
-- Generic on purpose. Two workflow templates exist (the generic one from 0008
-- and 'Sharda Marketing Workflow' from 0012, which is the default), and the PO
-- fork sits at a DIFFERENT stage in each: DEPARTMENT_APPROVAL in one,
-- FINAL_APPROVAL in the other. Naming either here would have silently fixed
-- one workflow and left the live one untouched.
--
-- So: wherever a PO_REQUIRED edge exists, point it at whatever its NO_PO
-- sibling points at. The fork collapses; po_required stops deciding the route.
UPDATE public.workflow_transitions po
   SET to_stage_id = nopo.to_stage_id,
       description = 'Approved — production starts; PO runs alongside'
  FROM public.workflow_transitions nopo
 WHERE po.trigger_condition   = 'PO_REQUIRED'
   AND nopo.trigger_condition = 'NO_PO'
   AND nopo.from_stage_id     = po.from_stage_id
   AND nopo.workflow_id       = po.workflow_id;


-- ----------------------------------------------------------------------------
-- Mark the four procurement stages as belonging to the parallel track, so the
-- UI can draw them as a side rail instead of numbering them 7-10 of the main
-- line. They stay in the table: work items imported before this migration may
-- still be sitting on one, and deleting the stage would orphan them.
-- ----------------------------------------------------------------------------
ALTER TABLE public.workflow_stages
  ADD COLUMN IF NOT EXISTS track TEXT NOT NULL DEFAULT 'MAIN';

ALTER TABLE public.workflow_stages
  DROP CONSTRAINT IF EXISTS chk_stage_track;
ALTER TABLE public.workflow_stages
  ADD CONSTRAINT chk_stage_track CHECK (track IN ('MAIN','PO'));

UPDATE public.workflow_stages
   SET track = 'PO'
 WHERE name IN ('PO_REQUEST','PROCUREMENT_REVIEW','PO_APPROVAL','PO_RELEASED');

COMMENT ON COLUMN public.workflow_stages.track IS
  'MAIN = the critical path. PO = the procurement track that runs in parallel.
   The stepper renders the two separately.';


-- ============================================================================
-- 2. The PO track itself
-- ============================================================================
-- work_items.po_status already had exactly the right five states
-- (NOT_STARTED -> REQUESTED -> IN_REVIEW -> APPROVED -> RELEASED, plus
-- REJECTED). Nothing new to model: what was missing was anything that MOVED
-- it, and anyone whose job it was to.
-- ----------------------------------------------------------------------------

-- Who approves a PO, and for what value. Resolved from approval_authorities
-- exactly like every other gate — never a constant in code.
CREATE OR REPLACE FUNCTION public.resolve_po_approver(p_amount NUMERIC DEFAULT NULL)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT aa.approver_id
  FROM public.approval_authorities aa
  WHERE aa.is_active
    AND aa.work_category = 'po'
    AND (p_amount IS NULL OR (
          aa.amount_min <= p_amount
          AND (aa.amount_max IS NULL OR aa.amount_max >= p_amount)))
  ORDER BY aa.approval_level, aa.amount_min DESC
  LIMIT 1;
$$;


-- ----------------------------------------------------------------------------
-- Open the PO track for a work item.
--
-- Called automatically by the trigger below when departmental approval is
-- given on PO work, and callable by hand for an item that needs a PO raised
-- earlier or later than usual.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.open_po_track(
  p_work_item_id UUID,
  p_amount       NUMERIC DEFAULT NULL,
  p_description  TEXT    DEFAULT NULL
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_work     public.work_items%ROWTYPE;
  v_po_id    UUID;
  v_approver UUID;
  v_stage    UUID;
BEGIN
  SELECT * INTO v_work FROM public.work_items WHERE id = p_work_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  -- Already open. Returning the existing PO rather than raising keeps the
  -- trigger below idempotent through re-approvals and return paths.
  IF v_work.po_request_id IS NOT NULL THEN
    RETURN v_work.po_request_id;
  END IF;

  v_approver := public.resolve_po_approver(p_amount);

  INSERT INTO public.po_requests (
    work_item_id, amount, description, status, raised_by, submitted_at
  ) VALUES (
    p_work_item_id,
    p_amount,
    COALESCE(p_description, 'Procurement for: ' || v_work.name),
    'SUBMITTED',
    auth.uid(),
    NOW()
  )
  RETURNING id INTO v_po_id;

  UPDATE public.work_items
     SET po_request_id = v_po_id,
         po_status     = 'REQUESTED'
   WHERE id = p_work_item_id;

  -- A task, so the PO shows up in somebody's My Work rather than depending on
  -- a person remembering to look. Without this the parallel track is invisible
  -- and simply becomes a slower version of the old serial one.
  SELECT id INTO v_stage
  FROM public.workflow_stages
  WHERE workflow_id = v_work.workflow_id AND name = 'PO_APPROVAL';

  IF v_approver IS NOT NULL THEN
    INSERT INTO public.tasks (
      work_item_id, stage_id, assignee_id, title, instructions,
      action_type, priority, due_date
    ) VALUES (
      p_work_item_id,
      v_stage,
      v_approver,
      'Raise and approve PO — ' || v_work.name,
      'Procurement runs alongside production. The work does not wait for this, '
        || 'but it cannot be released until the PO is issued.',
      'APPROVE_PO',
      v_work.priority,
      COALESCE(v_work.deadline, CURRENT_DATE + 3)
    );
  END IF;

  INSERT INTO public.activity_log (work_item_id, actor_id, action, to_value, detail)
  VALUES (p_work_item_id, auth.uid(), 'PO_TRACK_OPENED', 'REQUESTED',
          jsonb_build_object('po_request_id', v_po_id, 'approver_id', v_approver));

  RETURN v_po_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.open_po_track(UUID, NUMERIC, TEXT) TO authenticated;


-- ----------------------------------------------------------------------------
-- Advance the PO track one step, independently of the main workflow.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.advance_po_track(
  p_work_item_id UUID,
  p_to_status    TEXT,
  p_note         TEXT DEFAULT NULL
)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_work public.work_items%ROWTYPE;
  v_next TEXT := upper(btrim(p_to_status));
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.can_change_status() THEN
    RAISE EXCEPTION
      'Only Vijaya and Nirmal can move a purchase order along.'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_work FROM public.work_items WHERE id = p_work_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT v_work.po_required THEN
    RAISE EXCEPTION 'This work item does not need a purchase order'
      USING ERRCODE = '22023';
  END IF;

  IF v_next NOT IN ('REQUESTED','IN_REVIEW','APPROVED','RELEASED','REJECTED') THEN
    RAISE EXCEPTION 'Unknown PO status "%"', v_next USING ERRCODE = '22023';
  END IF;

  UPDATE public.work_items SET po_status = v_next WHERE id = p_work_item_id;

  UPDATE public.po_requests
     SET status = CASE v_next
                    WHEN 'REQUESTED' THEN 'SUBMITTED'
                    WHEN 'IN_REVIEW' THEN 'IN_REVIEW'
                    WHEN 'APPROVED'  THEN 'APPROVED'
                    WHEN 'RELEASED'  THEN 'RELEASED'
                    WHEN 'REJECTED'  THEN 'REJECTED'
                  END,
         approved_by = CASE WHEN v_next IN ('APPROVED','RELEASED')
                            THEN COALESCE(approved_by, auth.uid()) ELSE approved_by END,
         approved_at = CASE WHEN v_next = 'APPROVED' THEN COALESCE(approved_at, NOW())
                            ELSE approved_at END,
         released_at = CASE WHEN v_next = 'RELEASED' THEN COALESCE(released_at, NOW())
                            ELSE released_at END
   WHERE id = v_work.po_request_id;

  -- Close the PO task once procurement is done with it.
  IF v_next IN ('RELEASED','REJECTED') THEN
    UPDATE public.tasks
       SET closed_at = NOW(), status = 'COMPLETED', closed_reason = v_next
     WHERE work_item_id = p_work_item_id
       AND action_type = 'APPROVE_PO'
       AND closed_at IS NULL;
  END IF;

  INSERT INTO public.activity_log (work_item_id, actor_id, action, from_value, to_value, detail)
  VALUES (p_work_item_id, auth.uid(), 'PO_STATUS_CHANGED',
          v_work.po_status, v_next,
          CASE WHEN p_note IS NULL THEN NULL ELSE jsonb_build_object('note', p_note) END);

  RETURN v_next;
END;
$$;

GRANT EXECUTE ON FUNCTION public.advance_po_track(UUID, TEXT, TEXT) TO authenticated;


-- ============================================================================
-- 3. Open the track automatically, at the same moment approval is given
-- ============================================================================
-- "Simultaneously" has to mean automatically. If opening the PO track were a
-- button someone had to remember to press, procurement would start late again
-- — just for a different reason.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_open_po_track()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_left_po_fork_stage BOOLEAN;
BEGIN
  IF NOT NEW.po_required OR NEW.po_request_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- "The stage the PO fork hangs off", resolved from the transition table
  -- rather than named, for the same reason as above.
  SELECT EXISTS (
    SELECT 1 FROM public.workflow_transitions t
    WHERE t.from_stage_id = OLD.current_stage_id
      AND t.trigger_condition = 'PO_REQUIRED'
  ) INTO v_left_po_fork_stage;

  IF NEW.current_stage_id IS DISTINCT FROM OLD.current_stage_id
     AND v_left_po_fork_stage
  THEN
    PERFORM public.open_po_track(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

-- AFTER, not BEFORE: open_po_track writes to work_items itself, and doing that
-- from a BEFORE trigger on the same row is how you get a recursion that only
-- shows up in production.
DROP TRIGGER IF EXISTS trg_work_items_auto_po ON public.work_items;
CREATE TRIGGER trg_work_items_auto_po
  AFTER UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.auto_open_po_track();


-- ============================================================================
-- 4. The one constraint that survives: nothing goes live without its PO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.enforce_po_before_release()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_entering_release BOOLEAN;
BEGIN
  IF NOT NEW.po_required THEN RETURN NEW; END IF;
  IF NEW.current_stage_id IS NOT DISTINCT FROM OLD.current_stage_id THEN RETURN NEW; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.workflow_stages s
    WHERE s.id = NEW.current_stage_id AND s.name IN ('RELEASE','COMPLETED')
  ) INTO v_entering_release;

  IF v_entering_release AND NEW.po_status NOT IN ('RELEASED','NOT_REQUIRED') THEN
    RAISE EXCEPTION
      'This work cannot be released yet: its purchase order is %, not RELEASED. Production and approvals were free to run in parallel, but release waits for procurement.',
      NEW.po_status
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_items_po_before_release ON public.work_items;
CREATE TRIGGER trg_work_items_po_before_release
  BEFORE UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_po_before_release();


-- ============================================================================
-- 5. Make it easy to follow
-- ============================================================================
-- One row per PO step per work item, already ordered and already labelled
-- done / current / pending. The UI draws it; it does not compute it, so the
-- rail on screen and the rule in the database cannot disagree.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.po_step_rank(p_status TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_status
           WHEN 'NOT_STARTED' THEN 0
           WHEN 'REQUESTED'   THEN 1
           WHEN 'IN_REVIEW'   THEN 2
           WHEN 'APPROVED'    THEN 3
           WHEN 'RELEASED'    THEN 5   -- past the last step: all four are done
           ELSE 0
         END;
$$;

CREATE OR REPLACE VIEW public.v_po_track
WITH (security_invoker = TRUE) AS
WITH steps(step_order, code, label) AS (
  VALUES (1, 'REQUESTED', 'PO raised'),
         (2, 'IN_REVIEW', 'Procurement review'),
         (3, 'APPROVED',  'PO approved'),
         (4, 'RELEASED',  'Issued to vendor')
)
SELECT
  w.id AS work_item_id,
  s.step_order,
  s.code,
  s.label,
  CASE
    WHEN w.po_status = 'REJECTED' THEN 'rejected'
    WHEN s.step_order < public.po_step_rank(w.po_status) THEN 'done'
    WHEN s.step_order = public.po_step_rank(w.po_status) THEN 'current'
    ELSE 'pending'
  END AS state
FROM public.work_items w
CROSS JOIN steps s
WHERE w.po_required;

GRANT EXECUTE ON FUNCTION public.po_step_rank(TEXT) TO authenticated;
GRANT SELECT ON public.v_po_track TO authenticated;


-- ----------------------------------------------------------------------------
-- Backfill: items already sitting on a procurement stage move onto the main
-- track at Production, keeping the PO status they had. Without this they would
-- be stranded on a stage that no longer has an outgoing edge.
-- ----------------------------------------------------------------------------
UPDATE public.work_items w
   SET current_stage_id = prod.id,
       po_status = CASE
                     WHEN w.po_status IN ('NOT_REQUIRED','NOT_STARTED') THEN 'REQUESTED'
                     ELSE w.po_status
                   END
  FROM public.workflow_stages cur,
       public.workflow_stages prod
 WHERE w.current_stage_id = cur.id
   AND cur.track = 'PO'
   AND prod.workflow_id = cur.workflow_id
   AND prod.name = 'PRODUCTION';
