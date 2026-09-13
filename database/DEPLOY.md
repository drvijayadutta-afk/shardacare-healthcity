# Deploying to Vercel

## Root Directory must be `app`

The Next.js app lives in `app/`; `database/` and the docs are at the repository
root. So Vercel needs:

**Settings → Build and Deployment → Root Directory → `app`**

If it is empty or wrong you get either a 404 on every path (Vercel found no
framework at the root) or:

> The specified Root Directory "app" does not exist. Please update your Project Settings.

which means the setting is right but the branch being deployed does not contain
`app/` — check **Settings → Git → Production Branch**.

Root Directory cannot be set from `vercel.json`; it is a project setting only.

## Layout

```
app/        the Next.js application  (Vercel builds this)
database/   SQL bundle and these docs
```

## Environment variables — the one thing you must set

**Settings → Environment Variables**, for Production, Preview and Development:

| Name | Value |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://lwffqugbvbcmpgpsllft.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | see below |

### Finding the anon key

1. Open <https://supabase.com/dashboard/project/lwffqugbvbcmpgpsllft>
2. Left sidebar → **Project Settings** (the gear, bottom of the sidebar)
3. → **API**
4. Under **Project API keys**, copy the *public* key. Which label it carries
   depends on how old the project is:
   - **`anon` `public`** — a long JWT starting `eyJ…`
   - **publishable** — starts `sb_publishable_…`

   Either works. Never use one labelled **`service_role`** or **`secret`**.

   If sign-in fails with **"Invalid API key"**, the app now says why — it checks
   that the key's project matches the URL, that it is not a service key, and
   that it was not truncated or padded with whitespace.
5. The **Project URL** on the same page is the value for
   `NEXT_PUBLIC_SUPABASE_URL`.

### Adding them to Vercel

1. Open your project on <https://vercel.com>
2. **Settings → Environment Variables**
3. Add each name/value pair, tick all three environments, Save
4. **Deployments → ⋯ on the latest → Redeploy.** Environment variables are read
   at build time, so an existing deployment will not pick up new ones.

> **Never add the `service_role` key.** It bypasses row-level security
> completely. Every server route on Vercel can read the environment, so a
> service key there would expose every user's work to anyone who finds a way to
> echo it. The app never needs it — every query runs as the signed-in user,
> which is the entire point of the RLS design.

## What to expect

| State | Result |
|---|---|
| Deployed, env vars missing | Every page **500s**. `src/proxy.ts` builds a Supabase client per request and an undefined URL throws. A 500 here means the deploy worked — it is the next step, not a regression. |
| Env vars set, schema not applied | The login page renders. Signing in errors on missing tables. |
| Schema applied, signed in | `/my-work` loads and is **empty**. Correct: 31 of the 38 imported items have no assignee because the source document named none. |

## Order of operations

1. Push to the branch Vercel tracks — it builds automatically
2. Add the two environment variables → Redeploy
3. Supabase SQL Editor: `database/supabase-bundle/01_schema.sql`
4. Supabase SQL Editor: `database/supabase-bundle/02_seed.sql` — read
   `SEED_REVIEW.md` first, it lists two assumptions that change the data if wrong
5. Create a user (Supabase → Authentication → Users → Add user), sign in
6. Add `approval_authorities` rows so approvals route somewhere. The template is
   at the bottom of `supabase/migrations/0008_default_workflow.sql`

Steps 3–6 are unavoidable. The app is a front end over that schema; without it
every page errors regardless of how the deployment is configured.
