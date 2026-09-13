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

/* -------------------------------------------------------------------------- */
/* Key validation                                                              */
/* -------------------------------------------------------------------------- */

export type EnvProblem =
  | { kind: 'missing'; vars: string[] }
  | { kind: 'url_shape'; detail: string }
  | { kind: 'key_shape'; detail: string }
  | { kind: 'service_role_key'; detail: string }
  | { kind: 'project_mismatch'; detail: string };

/** Project ref out of https://<ref>.supabase.co */
function refFromUrl(url: string): string | null {
  const m = url.match(/^https:\/\/([a-z0-9]+)\.supabase\.(co|in)/i);
  return m ? m[1] : null;
}

/**
 * Decode a JWT payload without verifying it.
 *
 * Verification is Supabase's job and needs the signing secret. All we want is
 * the two claims that catch the mistakes people actually make: which project
 * the key belongs to, and whether it is the anon key or the service_role key.
 */
function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const json = Buffer.from(b64, 'base64').toString('utf8');
    return JSON.parse(json);
  } catch {
    return null;
  }
}

/**
 * Explain what is wrong with the configuration, so "Invalid API key" -- which
 * Supabase returns for every cause -- can be narrowed to the actual one.
 *
 * Deliberately conservative: only definite problems are reported. An
 * unrecognised but plausible key shape passes, because Supabase changes key
 * formats and a validator that rejects a working key is worse than one that
 * misses a broken one.
 */
export function diagnoseSupabaseEnv(): EnvProblem[] {
  const problems: EnvProblem[] = [];
  const env = readSupabaseEnv();

  if (!env.ok) return [{ kind: 'missing', vars: env.missing }];

  const { url, anonKey } = env.env;
  const urlRef = refFromUrl(url);

  if (!urlRef) {
    problems.push({
      kind: 'url_shape',
      detail:
        `NEXT_PUBLIC_SUPABASE_URL is "${url}", which is not of the form ` +
        'https://<project-ref>.supabase.co. Copy Project URL from Project Settings → API.',
    });
  }

  // Whitespace survives a careless paste into a dashboard field and produces
  // exactly this error, while looking completely correct on screen.
  if (anonKey !== anonKey.trim()) {
    problems.push({
      kind: 'key_shape',
      detail:
        'The key has leading or trailing whitespace. Re-paste it with no spaces ' +
        'or newlines — this alone causes "Invalid API key".',
    });
  }

  // A key copied from a wrapped display, or pasted through a field that folds
  // long values, carries a space or newline in the MIDDLE. The outer trim above
  // looks clean and the value looks right on screen, but it is not the key.
  if (/\s/.test(anonKey.trim())) {
    problems.push({
      kind: 'key_shape',
      detail:
        'The key contains a space or line break inside it, which usually means ' +
        'it was copied from a wrapped display. Re-copy it as one unbroken string.',
    });
  }

  const key = anonKey.trim();
  const isNewFormat = key.startsWith('sb_publishable_');
  const isSecretNewFormat = key.startsWith('sb_secret_');
  const payload = decodeJwtPayload(key);

  if (isSecretNewFormat) {
    problems.push({
      kind: 'service_role_key',
      detail:
        'This is a SECRET key (sb_secret_…). It must never be used here — it ' +
        'bypasses row-level security. Use the publishable key instead.',
    });
  } else if (payload) {
    const role = String(payload.role ?? '');
    const keyRef = String(payload.ref ?? '');

    if (role === 'service_role') {
      problems.push({
        kind: 'service_role_key',
        detail:
          'This is the service_role key. It bypasses row-level security ' +
          'entirely and must never be exposed to the browser. Use the anon key.',
      });
    } else if (role && role !== 'anon') {
      problems.push({
        kind: 'key_shape',
        detail: `The key's role is "${role}", expected "anon".`,
      });
    }

    if (urlRef && keyRef && keyRef !== urlRef) {
      problems.push({
        kind: 'project_mismatch',
        detail:
          `The key belongs to project "${keyRef}" but the URL points at ` +
          `"${urlRef}". They must be from the same project — this is the most ` +
          'common cause of "Invalid API key".',
      });
    }
  } else if (!isNewFormat) {
    problems.push({
      kind: 'key_shape',
      detail:
        'The key is neither a JWT (three dot-separated parts, starting "eyJ") ' +
        'nor a new-style key starting "sb_publishable_". ' +
        describeKeyShape(key),
    });
  }

  return problems;
}

/**
 * Describe a key's shape without printing it.
 *
 * Enough to spot a truncated, quoted, or name-prefixed paste. Deliberately
 * never reveals more than the first three characters: if someone has pasted a
 * SECRET key here by mistake, this page must not become the thing that leaks
 * it.
 */
function describeKeyShape(key: string): string {
  const bits: string[] = [`It is ${key.length} characters long`];

  if (key.length < 40) {
    bits.push('which is far shorter than any real key — it looks truncated');
  }
  const dots = (key.match(/\./g) ?? []).length;
  bits.push(`with ${dots} dot${dots === 1 ? '' : 's'} (a JWT has exactly 2)`);

  if (/^["']|["']$/.test(key)) {
    bits.push('and is wrapped in quotes — paste the value without them');
  }
  if (key.includes('=') && !key.startsWith('sb_')) {
    bits.push(
      'and contains "=" — if you pasted NAME=value, paste only the part after the "="',
    );
  }
  if (key.toUpperCase().startsWith('NEXT_PUBLIC')) {
    bits.push('and begins with the variable NAME rather than its value');
  }
  bits.push(`It starts "${key.slice(0, 3)}…"`);

  return bits.join(', ') + '.';
}
