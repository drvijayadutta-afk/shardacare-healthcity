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
  scripts/build-seed.mjs    regenerates the seed from the source job list
database/
  supabase-bundle/          the migrations concatenated for the Supabase SQL Editor
  SETUP.md                  applying the schema
  DEPLOY.md                 deploying to Vercel
  SEED_REVIEW.md            every place the source document was unclear
```

## Getting it running

1. `database/DEPLOY.md` — deployment and environment variables
2. `database/SETUP.md` — apply the schema and seed to Supabase
3. `database/SEED_REVIEW.md` — **read before seeding**; it lists 76 flags and two
   assumptions that change the data if they are wrong

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
```

## Known state

The schema, handoff engine and seed are verified against real Postgres. The
pages are compile-verified only — at the time of writing they have never
rendered a row from a live database.
