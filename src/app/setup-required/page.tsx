export const dynamic = 'force-dynamic';

function Var({ name, missing }: { name: string; missing: boolean }) {
  return (
    <li className="flex items-baseline gap-2">
      <span aria-hidden className={missing ? 'text-red-600' : 'text-emerald-600'}>
        {missing ? '✗' : '✓'}
      </span>
      <code className="text-xs">{name}</code>
      <span className={`text-xs ${missing ? 'text-red-700' : 'text-emerald-700'}`}>
        {missing ? 'not set' : 'set'}
      </span>
    </li>
  );
}

export default async function SetupRequiredPage({
  searchParams,
}: {
  searchParams: Promise<{ missing?: string }>;
}) {
  const { missing: raw } = await searchParams;
  const missing = (raw ?? '').split(',').filter(Boolean);
  const isMissing = (n: string) => missing.length === 0 || missing.includes(n);

  return (
    <main className="mx-auto max-w-xl px-4 py-16">
      <h1 className="text-xl font-semibold text-slate-900">
        Supabase is not configured
      </h1>
      <p className="mt-2 text-sm text-slate-600">
        The app deployed successfully. It cannot reach Supabase because these
        environment variables are missing from this build.
      </p>

      <ul className="mt-5 space-y-1.5 rounded-lg border border-slate-200 bg-white p-4">
        <Var name="NEXT_PUBLIC_SUPABASE_URL" missing={isMissing('NEXT_PUBLIC_SUPABASE_URL')} />
        <Var name="NEXT_PUBLIC_SUPABASE_ANON_KEY" missing={isMissing('NEXT_PUBLIC_SUPABASE_ANON_KEY')} />
      </ul>

      <h2 className="mt-8 text-sm font-semibold text-slate-900">Fixing it on Vercel</h2>
      <ol className="mt-2 list-decimal space-y-2 pl-5 text-sm text-slate-700">
        <li>Supabase dashboard → Project Settings → API.</li>
        <li>
          Copy <strong>Project URL</strong> and the key marked{' '}
          <strong>anon / public</strong> (it starts <code className="text-xs">eyJ</code>).
        </li>
        <li>Vercel → your project → Settings → Environment Variables. Add both, tick all environments, Save.</li>
        <li>
          <strong>Redeploy.</strong> <code className="text-xs">NEXT_PUBLIC_*</code> values are
          baked in when the site is built, so adding them to an existing deployment
          changes nothing until it is rebuilt. This is the usual reason this page
          persists after setting them.
        </li>
      </ol>

      <p className="mt-6 rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-900">
        Use the <strong>anon</strong> key, never <code className="text-xs">service_role</code>.
        The service key bypasses row-level security, and every server route can
        read the environment it is placed in.
      </p>

      <p className="mt-6 text-xs text-slate-500">
        Full instructions: <code>database/DEPLOY.md</code> in the repository.
        Once this page clears, the schema still has to be applied before signing
        in will work — see <code>database/SETUP.md</code>.
      </p>
    </main>
  );
}
