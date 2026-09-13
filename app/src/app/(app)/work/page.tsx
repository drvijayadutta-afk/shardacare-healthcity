import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { StatusBadge, PriorityBadge, OverdueBadge } from '@/components/Badges';
import { formatDate, formatDaysRemaining, humanise, DASH } from '@/lib/format';
import {
  FILTERS, PRIMARY_FILTERS, isFilterKey, applyFilter, applyOwnerFilter, type FilterKey,
} from '@/lib/workflow/filters';
import type { WorkItemRow } from '@/types/work';

export const dynamic = 'force-dynamic';

export default async function WorkListPage({
  searchParams,
}: {
  searchParams: Promise<{ filter?: string; owner?: string; name?: string }>;
}) {
  const { filter: raw, owner, name } = await searchParams;
  const filter: FilterKey = isFilterKey(raw) ? raw : 'active';

  const supabase = await createClient();
  let base = applyFilter(supabase.from('v_work_items').select('*'), filter);
  if (owner) base = applyOwnerFilter(base, owner);
  const query = base
    .order('stage_deadline', { ascending: true, nullsFirst: false })
    .limit(200);

  const { data, error } = await query;
  // applyFilter works on an untyped builder, so the row type is restored here.
  const rows = (data ?? []) as WorkItemRow[];

  return (
    <div>
      <div className="mb-4">
        <Link href="/control-tower" className="text-sm text-slate-500 hover:text-slate-900">
          ← Control Tower
        </Link>
        <h1 className="mt-2 text-xl font-semibold text-slate-900">
          {FILTERS[filter]}
          {name && <span className="font-normal text-slate-500"> · {name}</span>}
        </h1>
        <p className="mt-1 text-sm text-slate-500">
          {error ? 'Could not load' : `${rows.length} ${rows.length === 1 ? 'item' : 'items'}`}
        </p>
      </div>

      {(() => {
        const secondary = (Object.keys(FILTERS) as FilterKey[])
          .filter((k) => !PRIMARY_FILTERS.includes(k));
        const chip = (k: FilterKey) => (
          <Link
            key={k} href={`/work?filter=${k}`}
            className={`rounded-full px-2.5 py-1 text-xs font-medium ring-1 ring-inset ${
              k === filter
                ? 'bg-slate-900 text-white ring-slate-900'
                : 'bg-white text-slate-600 ring-slate-200 hover:bg-slate-50'}`}>
            {FILTERS[k]}
          </Link>
        );
        return (
          <div className="mb-4">
            <div className="flex flex-wrap gap-1.5">
              {PRIMARY_FILTERS.map(chip)}
            </div>
            {/* Open by default when the active filter is one of the "more" ones,
                so landing here from a link never hides which filter is applied. */}
            <details className="mt-1.5" open={secondary.includes(filter)}>
              <summary className="cursor-pointer text-xs font-medium text-slate-500 hover:text-slate-700">
                More filters
              </summary>
              <div className="mt-1.5 flex flex-wrap gap-1.5">
                {secondary.map(chip)}
              </div>
            </details>
          </div>
        );
      })()}

      {error ? (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700">
          {error.message}
        </div>
      ) : !rows.length ? (
        <div className="rounded-lg border border-slate-200 bg-white p-10 text-center text-sm text-slate-500">
          Nothing matches this filter.
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50">
              <tr className="text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                <th scope="col" className="px-4 py-3">Work</th>
                <th scope="col" className="px-4 py-3">Stage</th>
                <th scope="col" className="px-4 py-3">Owner</th>
                <th scope="col" className="px-4 py-3">Pending With</th>
                <th scope="col" className="px-4 py-3">Deadline</th>
                <th scope="col" className="px-4 py-3">Days</th>
                <th scope="col" className="px-4 py-3">Priority</th>
                <th scope="col" className="px-4 py-3">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((w) => (
                <tr key={w.id} className="hover:bg-slate-50">
                  <td className="px-4 py-3">
                    <Link href={`/work/${w.id}`}
                      className="font-medium text-slate-900 underline-offset-2 hover:underline">
                      {w.name}
                    </Link>
                    {w.job_name && w.job_name !== w.name && (
                      <div className="mt-0.5 text-xs text-slate-500">{w.job_name}</div>
                    )}
                  </td>
                  <td className="px-4 py-3 text-slate-600">{humanise(w.stage_name)}</td>
                  <td className="px-4 py-3 text-slate-600">{w.owner_name ?? DASH}</td>
                  <td className="px-4 py-3 text-slate-600">
                    <span className={w.pending_with === 'unassigned' || w.pending_with === 'unknown'
                      ? 'text-amber-700' : ''}>{w.pending_with ?? DASH}</span>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-slate-600">
                    {formatDate(w.stage_deadline ?? w.deadline)}
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap">
                    <span className={w.is_overdue ? 'font-medium text-red-700' : 'text-slate-600'}>
                      {formatDaysRemaining(w.days_remaining)}
                    </span>
                  </td>
                  <td className="px-4 py-3"><PriorityBadge priority={w.priority} /></td>
                  <td className="px-4 py-3">
                    <div className="flex flex-wrap items-center gap-1">
                      <StatusBadge status={w.status} />
                      <OverdueBadge days={w.days_remaining} />
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
