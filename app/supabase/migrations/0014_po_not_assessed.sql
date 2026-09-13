-- ============================================================================
-- 0014_po_not_assessed.sql — stop silently asserting "PO not required"
-- ============================================================================
-- work_items.po_required defaults to FALSE and po_status defaults to
-- 'NOT_REQUIRED' (0003_work.sql). The seed importer never set either column
-- explicitly, so every imported row fell through to those defaults — which
-- means the app has been claiming, with the same confidence as an item whose
-- source actually said "no PO needed", that a purchase order was considered
-- and ruled out for all 38 imported items. The source document never
-- mentions a purchase order once, for any of them. That is an invented fact,
-- not a read one.
--
-- po_required stays a NOT NULL boolean -- there is no way to make FALSE mean
-- "unknown" without breaking every existing query and RPC that branches on
-- it. po_status can and does distinguish the two: NOT_ASSESSED now means
-- "nobody has said", NOT_REQUIRED keeps meaning "confirmed, no PO needed".
-- ============================================================================

ALTER TABLE public.work_items DROP CONSTRAINT IF EXISTS chk_work_po_status;
ALTER TABLE public.work_items ADD CONSTRAINT chk_work_po_status CHECK (po_status IN (
  'NOT_ASSESSED','NOT_REQUIRED','NOT_STARTED','REQUESTED','IN_REVIEW','APPROVED','RELEASED','REJECTED'
));

-- Backfill only imported rows (source_ref IS NOT NULL) that are still sitting
-- on the untouched default. A work item created through the app has a human
-- who actually ticked or left unticked "a purchase order is needed" -- that
-- is a real decision, not a default, and must not be overwritten.
UPDATE public.work_items
SET po_status = 'NOT_ASSESSED'
WHERE source_ref IS NOT NULL
  AND po_required = FALSE
  AND po_status = 'NOT_REQUIRED';
