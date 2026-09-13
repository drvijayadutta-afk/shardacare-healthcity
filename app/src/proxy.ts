import { type NextRequest } from 'next/server';
import { updateSession } from '@/lib/supabase/proxy';

// Next 16 renamed the `middleware` file convention to `proxy`; the old name
// still works but is deprecated. See
// node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/proxy.md
export async function proxy(request: NextRequest) {
  return await updateSession(request);
}

export const config = {
  // Without a matcher this runs on every request including static assets, so
  // the negative lookahead keeps auth redirects away from CSS, JS and images.
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
};
