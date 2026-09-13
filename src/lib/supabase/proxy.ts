import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { requireSupabaseEnv, readSupabaseEnv } from '@/lib/env';

/** Routes reachable without a session. Everything else requires one. */
const PUBLIC_PATHS = ['/login', '/auth'];

/** Shown in place of every route while Supabase env vars are missing. */
const SETUP_PATH = '/setup-required';

export async function updateSession(request: NextRequest) {
  // Checked before any client is built. Without this the proxy throws on every
  // route -- /login included -- and the whole site returns a bare "Internal
  // Server Error" that names nothing. Rewriting to a setup page instead means a
  // misconfigured deployment explains itself.
  const envCheck = readSupabaseEnv();
  if (!envCheck.ok) {
    if (request.nextUrl.pathname === SETUP_PATH) {
      return NextResponse.next({ request });
    }
    const url = request.nextUrl.clone();
    url.pathname = SETUP_PATH;
    url.search = `?missing=${encodeURIComponent(envCheck.missing.join(','))}`;
    // A rewrite, not a redirect: the address bar keeps the path the user asked
    // for, so the page is not mistaken for a permanent move.
    return NextResponse.rewrite(url);
  }

  let response = NextResponse.next({ request });

  const env = requireSupabaseEnv();

  const supabase = createServerClient(
    env.url,
    env.anonKey,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // getUser() revalidates the token with Supabase on every request. getSession()
  // would only decode the cookie, which the client can tamper with — so this
  // must not be "optimised" into getSession().
  const { data: { user } } = await supabase.auth.getUser();

  const path = request.nextUrl.pathname;
  const isPublic = PUBLIC_PATHS.some((p) => path === p || path.startsWith(p + '/'));

  if (!user && !isPublic) {
    const url = request.nextUrl.clone();
    url.pathname = '/login';
    // Remember where they were headed so login can return them there.
    url.searchParams.set('next', path);
    return NextResponse.redirect(url);
  }

  if (user && path === '/login') {
    const url = request.nextUrl.clone();
    url.pathname = '/my-work';
    url.search = '';
    return NextResponse.redirect(url);
  }

  return response;
}
