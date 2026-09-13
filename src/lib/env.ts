/**
 * Supabase environment configuration.
 *
 * These are read in three places (browser client, server client, proxy) and a
 * missing value used to surface as an opaque 500 on EVERY route -- including
 * /login -- because the proxy runs first and `@supabase/ssr` throws when handed
 * undefined. "Internal Server Error" named nothing and gave no way to tell a
 * misconfigured deploy from a broken one.
 *
 * Reading them through here lets the proxy detect the problem and show a page
 * that says which variable is missing instead of crashing.
 *
 * NEXT_PUBLIC_* values are inlined at build time, so a Vercel deployment built
 * before the variables were added will still be missing them. Adding them
 * requires a redeploy, which is the single most common cause of this state.
 */

export interface SupabaseEnv {
  url: string;
  anonKey: string;
}

export function readSupabaseEnv():
  | { ok: true; env: SupabaseEnv }
  | { ok: false; missing: string[] } {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  const missing: string[] = [];
  if (!url?.trim()) missing.push('NEXT_PUBLIC_SUPABASE_URL');
  if (!anonKey?.trim()) missing.push('NEXT_PUBLIC_SUPABASE_ANON_KEY');

  if (missing.length > 0) return { ok: false, missing };
  return { ok: true, env: { url: url!, anonKey: anonKey! } };
}

/**
 * For the three client factories. Throws a message naming the variables, so if
 * one is ever constructed outside the proxy's guard the log says what to fix
 * rather than "URL and API key are required".
 */
export function requireSupabaseEnv(): SupabaseEnv {
  const result = readSupabaseEnv();
  if (!result.ok) {
    throw new Error(
      `Supabase is not configured. Missing: ${result.missing.join(', ')}. ` +
        'Set these in your hosting environment and redeploy — NEXT_PUBLIC_* ' +
        'values are baked in at build time, so adding them without a rebuild ' +
        'has no effect. See database/DEPLOY.md.',
    );
  }
  return result.env;
}
