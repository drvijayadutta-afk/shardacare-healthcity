# Deploying to Vercel

## Why the first deploy returned 404

The Next.js app is **not** at the repository root:

```
repo root/          <- Vercel builds here by default. No package.json.
├── database/
├── WORKFLOW_ANALYSIS.md
└── app/            <- the actual Next.js app
    └── package.json
```

With no `package.json` at the root, Vercel detects no framework, builds nothing,
and serves `404: NOT_FOUND` on every path. The build log shows nothing to build
rather than an error, which is why it looks like the app is broken when it is
not — nothing was ever deployed.

## Fix (Vercel dashboard)

### 1. Root Directory

**Settings → General → Root Directory** → `app` → Save.

This is the whole fix for the 404. It cannot be set from `vercel.json`; it is a
project setting only.

### 2. Environment variables

**Settings → Environment Variables**, for Production, Preview and Development:

| Name | Value |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://lwffqugbvbcmpgpsllft.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase → Project Settings → API → anon/publishable key |

**Do not add the `service_role` key.** It bypasses row-level security entirely.
Every server route on Vercel can read the environment, so a leaked or misused
service key there would expose every user's work. The app never needs it —
every query runs as the signed-in user, which is the point of the RLS design.

### 3. Redeploy

Environment variables are read at build time. An existing deployment will not
pick up variables added after it was built, so trigger a fresh deploy.

## What to expect after each step

| After | You should see |
|---|---|
| Root Directory set, but no env vars | The app deploys, then **500s** on every page. `proxy.ts` builds a Supabase client per request and an undefined URL throws. A 500 here is progress, not a new fault. |
| Env vars added and redeployed | `/` redirects to `/my-work`, which redirects to `/login`. The login form renders. |
| Signing in before the SQL is applied | Errors from Supabase about missing tables. Apply the schema first — see `SETUP.md`. |
| Signing in after the SQL is applied | `/my-work` loads and is **empty**. That is correct: 31 of the 38 imported items have no assignee, because the source document named none. |

## Order of operations

1. Vercel: Root Directory → `app`
2. Vercel: environment variables → redeploy
3. Supabase SQL Editor: `supabase-bundle/01_schema.sql`
4. Supabase SQL Editor: `supabase-bundle/02_seed.sql` — read `SEED_REVIEW.md` first
5. Create a user, sign in
6. Add `approval_authorities` rows so approvals route somewhere; the template is
   at the bottom of `app/supabase/migrations/0008_default_workflow.sql`

Steps 3–6 are unavoidable: the app is a front end over that schema, and without
it every page errors no matter how well the deployment is configured.
