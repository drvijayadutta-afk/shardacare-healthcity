import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';
import { requireSupabaseEnv } from '@/lib/env';

/**
 * Supabase client for Server Components, Server Actions and Route Handlers.
 *
 * Always uses the anon key and the caller's own session cookie, never the
 * service_role key. That is what keeps row-level security in force: every
 * query runs as the signed-in user, so "you see only your own work" is
 * enforced by the database rather than by a WHERE clause we have to remember
 * to write.
 */
export async function createClient() {
  const cookieStore = await cookies();

  const env = requireSupabaseEnv();

  return createServerClient(
    env.url,
    env.anonKey,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {
            // Called from a Server Component, where cookies are read-only.
            // Session refresh is handled by middleware instead, so ignoring
            // this is safe rather than merely convenient.
          }
        },
      },
    },
  );
}
