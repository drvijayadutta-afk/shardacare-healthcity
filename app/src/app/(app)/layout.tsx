import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getCurrentUser, canViewAllWork } from '@/lib/auth/roles';
import { QuickAddWork } from '@/components/QuickAddWork';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect('/login');

  const showControlTower = canViewAllWork(user);

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-6 gap-y-2 px-4 py-3">
          <Link href="/my-work" className="text-sm font-semibold text-black">
            Workflow Control Tower
          </Link>
          <nav className="flex items-center gap-4 text-sm">
            <Link href="/my-work" className="text-black hover:text-black">My Work</Link>
            {showControlTower && (
              <Link href="/control-tower" className="text-black hover:text-black">
                Control Tower
              </Link>
            )}
            {showControlTower && (
              <Link href="/board" className="text-black hover:text-black">
                Board
              </Link>
            )}
          </nav>
          <div className="ml-auto flex items-center gap-3">
            {showControlTower && <QuickAddWork />}
            <span className="text-sm text-black">{user.fullName}</span>
            <form action="/auth/signout" method="post">
              <button type="submit" className="text-sm text-black hover:text-black">
                Sign out
              </button>
            </form>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-7xl px-4 py-6">{children}</main>
    </div>
  );
}
