import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { getCurrentUser } from '@/lib/auth/roles';
import { StatusBadge, PriorityBadge, OverdueBadge } from '@/components/Badges';
import { formatDate, formatDaysRemaining, actionLabel, humanise, DASH } from '@/lib/format';

export const dynamic = 'force-dynamic';

interface TaskRow {
  task_id: string;
  work_item_id: string;
  work_name: string;
  job_name: string | null;
  campaign_name: string | null;
  stage_name: string | null;
  task_status: string;
  work_status: string;
  task_priority: string;
  pending_with: string | null;
  action_type: string;
  effective_due_date: string | null;
  days_remaining: number | null;
  is_overdue: boolean | null;
}

export default async function MyWorkPage() {
  const user = await getCurrentUser();
  const supabase = await createClient();

  // v_my_tasks is already scoped to the caller: it filters on auth.uid() and
  // RLS applies on top. No client-side "where assignee = me" is needed, and
  // adding one would give a false sense of where the boundary lives.
  const { data, error } = await supabase
    .from('v_my_tasks')
    .select('*')
    .order('effective_due_date', { ascending: true, nullsFirst: false })
    .order('task_priority', { ascending: true });

  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-4">
        <h1 className="font-medium text-red-800">Could not load your work</h1>
        <p className="mt-1 text-sm text-red-700">{error.message}</p>
      </div>
    );
  }

  const tasks = (data ?? []) as TaskRow[];
  const overdue = tasks.filter((t) => t.is_overdue).length;

  return (
    <div>
      <div className="mb-5 flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h1 className="text-xl font-semibold text-slate-900">My Work</h1>
        <p className="text-sm text-slate-500">
          {tasks.length === 0
            ? 'Nothing assigned to you'
            : `${tasks.length} open ${tasks.length === 1 ? 'item' : 'items'}`}
          {overdue > 0 && <span className="ml-1 font-medium text-red-700">· {overdue} overdue</span>}
        </p>
      </div>

      {tasks.length === 0 ? (
        <div className="rounded-lg border border-slate-200 bg-white p-10 text-center">
          <p className="text-sm font-medium text-slate-900">Your queue is empty</p>
          <p className="mt-1 text-sm text-slate-500">
            Work appears here the moment someone hands it to you.
          </p>
          <p className="mt-3 text-xs text-slate-400">
            Signed in as {user?.fullName}
            {user && user.roles.length > 0 && ` · ${user.roles.map(humanise).join(', ')}`}
          </p>
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50">
              <tr className="text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                <th scope="col" className="px-4 py-3">Work</th>
                <th scope="col" className="px-4 py-3">Campaign</th>
                <th scope="col" className="px-4 py-3">Current Stage</th>
                <th scope="col" className="px-4 py-3">Due Date</th>
                <th scope="col" className="px-4 py-3">Days Remaining</th>
                <th scope="col" className="px-4 py-3">Priority</th>
                <th scope="col" className="px-4 py-3">Status</th>
                <th scope="col" className="px-4 py-3">Pending With</th>
                <th scope="col" className="px-4 py-3">Pending Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {tasks.map((t) => (
                <tr key={t.task_id} className="hover:bg-slate-50">
                  <td className="px-4 py-3">
                    <Link
                      href={`/work/${t.work_item_id}`}
                      className="font-medium text-slate-900 underline-offset-2 hover:underline"
                    >
                      {t.work_name}
                    </Link>
                    {t.job_name && t.job_name !== t.work_name && (
                      <div className="mt-0.5 text-xs text-slate-500">{t.job_name}</div>
                    )}
                  </td>
                  <td className="px-4 py-3 text-slate-600">{t.campaign_name ?? DASH}</td>
                  <td className="px-4 py-3 text-slate-600">{humanise(t.stage_name)}</td>
                  <td className="px-4 py-3 whitespace-nowrap text-slate-600">
                    {formatDate(t.effective_due_date)}
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap">
                    <span className={t.is_overdue ? 'font-medium text-red-700' : 'text-slate-600'}>
                      {formatDaysRemaining(t.days_remaining)}
                    </span>
                  </td>
                  <td className="px-4 py-3"><PriorityBadge priority={t.task_priority} /></td>
                  <td className="px-4 py-3">
                    <div className="flex flex-wrap items-center gap-1">
                      <StatusBadge status={t.work_status} />
                      <OverdueBadge days={t.days_remaining} />
                    </div>
                  </td>
                  <td className="px-4 py-3 text-slate-600">{t.pending_with ?? DASH}</td>
                  <td className="px-4 py-3 text-slate-600">{actionLabel(t.action_type)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
