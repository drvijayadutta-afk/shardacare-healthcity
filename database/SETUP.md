# Applying the schema to Supabase

Project: `lwffqugbvbcmpgpsllft`

Two files, run in order, in the **SQL Editor** (Dashboard → SQL Editor → New query).
Both are idempotent — running them twice changes nothing the second time, which
has been verified against Postgres 16, not assumed.

## 1. Schema — `database/supabase-bundle/01_schema.sql`

Creates 21 tables, 2 views, 51 RLS policies and the handoff functions.

Paste the whole file, Run. Expect a wall of `NOTICE: ... already exists, skipping`
on any re-run; those are not errors.

**Do not** run anything from `supabase/testing/` — that is a local-only stand-in
for the `auth` schema, which your project already has.

## 2. Seed — `database/supabase-bundle/02_seed.sql`

Imports the 10th Sept job list: 30 jobs, 38 work items, 17 people.

Before running it, read **`database/SEED_REVIEW.md`**. It lists all 76 places
the source document did not say something, and two assumptions worth
confirming up front:

- **Year 2026** — the source omits the year on every date except one
  ("26th Sept 2026"). If that is wrong, every imported deadline is wrong.
- **Roles** — the document states no roles for anyone, so all 17 people are
  seeded as `CREATOR`. That exists only so RLS can be tested; reassign properly
  before real use.

The 17 people are created with `@placeholder.invalid` email addresses because
the document gives no contact details. When the real person signs up, match on
name and re-point the foreign keys — do not create a second row.

## 3. Create your login — `database/supabase-bundle/03_first_user.sql`

There is no sign-up page; this is an internal tool, so accounts are created by
an admin.

1. Supabase → **Authentication → Users → Add user**
2. Enter the email and a password, and **tick "Auto Confirm User"** — without it
   the account cannot sign in until the confirmation email is clicked.
3. Run `03_first_user.sql` in the SQL Editor.

It grants ADMIN, WORKFLOW_MANAGER, COORDINATOR and APPROVER, and registers the
account as the approver for all three approval gates so handoffs have somewhere
to route. Reassign those to the real approvers later — it is an UPDATE, not a
deploy.

**Order matters, and the script handles it either way.** `01_schema.sql`
installs a trigger that creates a profile row whenever an auth user is added.
A user created *before* the schema was applied never fires that trigger and
ends up with an account but no profile — signed in, then broken. The script
backfills that case.

## 4. App environment

```bash
cp .env.local.example .env.local
```

Fill in `NEXT_PUBLIC_SUPABASE_ANON_KEY` from Project Settings → API.

Only the URL and anon key are needed. The **service_role key is not required and
should not be added** — it bypasses row-level security entirely, which would
defeat the "a user sees only their own work" guarantee that the whole schema is
built around.

## 5. Verify it took

Run this in the SQL Editor:

```sql
SELECT
  (SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='public' AND table_type='BASE TABLE')      AS tables,
  (SELECT COUNT(*) FROM pg_policies WHERE schemaname='public')     AS rls_policies,
  (SELECT COUNT(*) FROM work_items)                                AS work_items,
  (SELECT COUNT(*) FROM work_items WHERE needs_review)             AS needs_review,
  (SELECT COUNT(*) FROM work_items WHERE deadline IS NULL)         AS no_deadline;
```

Expected: **21 tables · 51 policies · 38 work items · 38 needing review · 20 with no deadline**.

38-of-38 needing review is correct, not a bug: the source is a terse internal
list, and almost every line omits at least one of owner, deadline or status.

## What is NOT set up yet

The workflow itself. Imported rows sit in a holding template called
*Imported (unclassified)* with three stages, because the source document does not
say what stage anything is at.

The real 11-stage flow (Request → Brief → Content → Design → Internal Review →
Department Approval → PO → Production → Final Approval → Release → Completed),
its SLAs, and the `approval_authorities` rows that decide who approves what, are
all configuration that still needs to be entered. Nothing in the engine depends
on a specific person or deadline — that is the whole design — but it does need
those rows to exist before a real handoff can route anywhere.
