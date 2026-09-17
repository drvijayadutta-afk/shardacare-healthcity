-- ============================================================================
-- 0030_soft_delete_imported_job_list.sql — retire the 10th Sept job-list
--   import
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Soft-deletes (not hard-deletes) the 30 jobs and 38 work items originally
-- imported from the 10th Sept source document by app/scripts/build-seed.mjs
-- -- confirmed to identify exactly and only that data: jobs.source_ref LIKE
-- 'joblist:job:%' and work_items.source_ref LIKE 'joblist:item:%' are
-- populated ONLY by that import (see 0003_work.sql's own comment: "Nullable
-- ... hand-created jobs have none"), so nothing created through the app
-- itself matches these patterns.
--
-- Deliberately soft, not hard: every list/board/dashboard view already
-- filters deleted_at (v_work_items -- 0005_views.sql -- and everything that
-- reads through it: Control Tower metrics, Board, Work list, My Work), so
-- this is enough to make the import disappear from the app everywhere,
-- while staying recoverable (UPDATE ... SET deleted_at = NULL) if this
-- turns out to be a mistake -- a hard DELETE would cascade through tasks,
-- comments, files, activity_log, submissions, approvals and po_requests via
-- ON DELETE CASCADE and could not be undone.
--
-- Deliberately does NOT touch the 17 people the import also created
-- (public.users rows) -- several, like Anshika and Vidisha, have since been
-- given real emails and real discipline roles and are referenced by other
-- things; deleting the job list should not touch them.
--
-- Companion change: app/scripts/build-seed.mjs no longer emits jobs/work
-- items on a future run (people/roles/workflow-template setup is
-- unaffected), so a fresh install of this app won't re-import this list.
-- ============================================================================

UPDATE public.jobs
   SET deleted_at = NOW()
 WHERE source_ref LIKE 'joblist:job:%'
   AND deleted_at IS NULL;

UPDATE public.work_items
   SET deleted_at = NOW()
 WHERE source_ref LIKE 'joblist:item:%'
   AND deleted_at IS NULL;
