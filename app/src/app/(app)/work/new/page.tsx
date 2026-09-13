import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { getCurrentUser, canViewAllWork } from '@/lib/auth/roles';
import { NewWorkForm, type Person } from '@/components/NewWorkForm';

export const dynamic = 'force-dynamic';

export default async function NewWorkPage() {
  const user = await getCurrentUser();
  // Matches the RLS policy on work_items INSERT, so the form is not offered to
  // someone the database would refuse.
  if (!canViewAllWork(user)) redirect('/my-work');

  const supabase = await createClient();
  const { data } = await supabase
    .from('users')
    .select('id, full_name, user_roles(roles(name))')
    .eq('is_active', true)
    .order('full_name');

  type Row = { id: string; full_name: string; user_roles: { roles: { name: string } | null }[] };
  const people: Person[] = ((data ?? []) as unknown as Row[]).map((u) => ({
    id: u.id,
    full_name: u.full_name,
    roles: (u.user_roles ?? []).map((r) => r.roles?.name).filter(Boolean) as string[],
  }));

  return (
    <div className="max-w-3xl">
      <Link href="/control-tower" className="text-sm text-slate-500 hover:text-slate-900">
        ← Control Tower
      </Link>
      <h1 className="mt-2 text-xl font-semibold text-slate-900">Add work</h1>
      <p className="mb-6 mt-1 text-sm text-slate-500">
        Starts at the leadership brief. Every handoff after that is automatic.
      </p>
      <NewWorkForm people={people} />
    </div>
  );
}
