# Deploying to Vercel

## If your build says the Root Directory does not exist

> The specified Root Directory "app" does not exist. Please update your Project Settings.

**Vercel → Settings → General → Root Directory → clear the field → Save → Redeploy.**

An earlier version of this project kept the app in an `app/` subdirectory, and
deployments from that era have Root Directory set to `app`. The app has since
moved to the repository root and that directory no longer exists, so the setting
now points at nothing. An empty field means the repository root, which is
where Vercel should look.

This cannot be fixed from `vercel.json` — Root Directory is a project setting
only.

## Layout

The app sits at the repository root — `package.json`, `next.config.ts` and
`src/` are all top level. Vercel detects Next.js automatically, so **no Root
Directory setting is needed**.

> Earlier the app lived in `app/`, which made Vercel build the repository root,
> find no `package.json`, produce no output and return `404: NOT_FOUND` on every
> path. Moving it to the root removed that failure mode rather than working
> around it with a dashboard setting someone would have to remember.

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
