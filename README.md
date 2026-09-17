# Marketing Workflow Control Tower

Internal work allocation and handoff system for the Sharda Hospital
marketing/creative team. A person receives work, submits it, and the system
advances the workflow stage and assigns the next person automatically.

## Layout

The Next.js app is in **`app/`** — Vercel's Root Directory is set to match.
SQL and documentation stay at the repository root.

```
app/
  src/app/(app)/            my-work, work/[id], work, control-tower
  src/lib/workflow/         server actions wrapping the handoff functions
  supabase/migrations/      the schema — SOURCE OF TRUTH
  supabase/testing/         SQL test suites (local Postgres, not Supabase)
  scripts/build-seed.mjs    regenerates the seed (people only — see below)
database/
  supabase-bundle/          the migrations concatenated for the Supabase SQL Editor
  SETUP.md                  applying the schema
  DEPLOY.md                 deploying to Vercel
  SEED_REVIEW.md            why the original job-list import was retired
```

## Getting it running

1. `database/DEPLOY.md` — deployment and environment variables
2. `database/SETUP.md` — apply the schema and seed to Supabase

The seed originally imported the 10th Sept job list (30 jobs, 38 work items) —
that import was retired (`0030_soft_delete_imported_job_list.sql`, soft-deleted
not hard-deleted) and `build-seed.mjs` no longer emits it. The people named in
the source document, their role assignments, and the "Imported (unclassified)"
workflow template are unaffected. See `database/SEED_REVIEW.md`.

Local development:

```bash
cd app
cp .env.local.example .env.local   # then add the anon key
npm install
npm run dev
```

## How the workflow is configured

Stages, transitions, SLAs and approval routing are **rows, not code**. The engine
resolves the next assignee by querying `approval_authorities` and never branches
on a stage name, so approvers and deadlines change without a deploy.

The 11-stage flow and its procurement detour are defined in
`app/supabase/migrations/0008_default_workflow.sql`.

## Tests

```bash
# needs a local Postgres; see the header of each file
psql -f app/supabase/testing/00_auth_shim.sql   # stands in for Supabase's auth schema
psql -f app/supabase/testing/01_smoke_test.sql  # handoff engine, 10 cases
psql -f app/supabase/testing/02_workflow_test.sql  # full 11-stage walk, both PO branches
psql -f app/supabase/testing/03_sharda_workflow_test.sql  # the real team, by name
psql -f app/supabase/testing/04_admin_controls_test.sql  # add/reassign/delete-task role gates (status controller + admin, see 0026)
psql -f app/supabase/testing/05_permissions_and_po_test.sql  # status control, parallel PO, tags, creative chain
psql -f app/supabase/testing/06_job_creation_test.sql  # only ADMIN may create jobs/work items
psql -f app/supabase/testing/07_status_controller_override_test.sql  # controller/admin can act on work that isn't theirs, RLS included
psql -f app/supabase/testing/08_po_and_audit_rls_test.sql  # PO self-attribution closed, controller PO override, audit trail can't be forged
psql -f app/supabase/testing/09_work_visible_to_all_test.sql  # everyone can see all work; editing/deleting stays role-gated
psql -f app/supabase/testing/10_task_control_restricted_test.sql  # only status controllers/admin can add, reassign or delete a task
psql -f app/supabase/testing/11_job_list_retired_test.sql  # 0030 soft-deletes only joblist:-sourced rows, hand-created work is untouched
```

Run against the same database, in this order — 02 seeds and restores approval
authorities that 03 depends on to route MANAGER_APPROVAL.

## Known state

The schema, handoff engine and seed are verified against real Postgres. The
pages are compile-verified only — at the time of writing they have never
rendered a row from a live database.
