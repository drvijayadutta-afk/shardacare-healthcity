'use client';

import { createBrowserClient } from '@supabase/ssr';
import { requireSupabaseEnv } from '@/lib/env';

/** Supabase client for Client Components (login form, interactive widgets). */
export function createClient() {
  const env = requireSupabaseEnv();

  return createBrowserClient(
    env.url,
    env.anonKey,
  );
}
