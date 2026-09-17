import { createClient } from '@/lib/supabase/server';
import { NextResponse } from 'next/server';

/**
 * Where every Supabase auth email link lands (password reset today; the same
 * route works for a future magic-link or invite flow without change). The
 * link carries a one-time `code`; exchanging it for a session is what
 * actually signs the browser in, so /auth/reset-password can trust it has
 * one rather than re-deriving auth state itself.
 */
export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get('code');
  const next = searchParams.get('next') ?? '/my-work';

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  // No code, or the link was already used / has expired — send them back to
  // request a fresh one rather than stranding them on a dead-end page.
  return NextResponse.redirect(`${origin}/login?error=reset-link-invalid`);
}
