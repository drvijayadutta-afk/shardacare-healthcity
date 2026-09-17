# Seed Import — Retired

The job-list import (30 jobs, 38 work items from **Job_list_10th_Sept_3.docx**)
was retired: soft-deleted from the live database
(`0030_soft_delete_imported_job_list.sql`) and no longer emitted by
`scripts/build-seed.mjs` (`EMIT_JOB_LIST_IMPORT = false`), so a fresh
install of this app won't re-import it.

People named in the document, their role assignments, and the "Imported
(unclassified)" workflow template are unaffected — this only concerns the
job/work-item rows themselves.

The full flag-by-flag review this file used to contain is in git history
(before this change) if it's ever needed again — e.g. `git log -p --
database/SEED_REVIEW.md`.
