import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { StatusBadge, PriorityBadge, OverdueBadge } from '@/components/Badges';
import { formatDate, formatDaysRemaining, DASH } from '@/lib/format';
import {
  FILTERS, PRIMARY_FILTERS, isFilterKey, applyFilter, applyOwnerFilter, type FilterKey,
} from '@/lib/workflow/filters';
import { JourneySummary, type JourneyStage } from '@/components/JourneyPills';
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

  // One query for every row's journey rather than one per row. The list is
  // capped at 200 items above, so this stays a single bounded fetch.
  const journeys = new Map<string, JourneyStage[]>();
  if (rows.length) {
    const { data: steps } = await supabase
      .from('v_work_item_journey')
      .select('work_item_id, stage_id, stage_name, stage_order, track, requires_approval, is_terminal, state, person_name, person_id, role_name, acted_at')
      .in('work_item_id', rows.map((r) => r.id));

    for (const step of (steps ?? []) as (JourneyStage & { work_item_id: string })[]) {
      const list = journeys.get(step.work_item_id);
      if (list) list.push(step);
      else journeys.set(step.work_item_id, [step]);
    }
  }

  return (
    <div>
      <div className="mb-4">
        <Link href="/control-tower" className="text-sm text-black hover:text-black">
          ← Control Tower
        </Link>
        <h1 className="mt-2 text-xl font-semibold text-black">
          {FILTERS[filter]}
          {name && <span className="font-normal text-black"> · {name}</span>}
        </h1>
        <p className="mt-1 text-sm text-black">
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
                : 'bg-white text-black ring-slate-200 hover:bg-slate-50'}`}>
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
              <summary className="cursor-pointer text-xs font-medium text-black hover:text-black">
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
        <div className="rounded-lg border border-slate-200 bg-white p-10 text-center text-sm text-black">
          Nothing matches this filter.
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50">
              <tr className="text-left text-xs font-medium uppercase tracking-wide text-black">
                <th scope="col" className="px-4 py-3">Work</th>
                <th scope="col" className="px-4 py-3">Journey</th>
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
                      className="font-medium text-black underline-offset-2 hover:underline">
                      {w.name}
                    </Link>
                    {w.job_name && w.job_name !== w.name && (
                      <div className="mt-0.5 text-xs text-black">{w.job_name}</div>
                    )}
                  </td>
                  <td className="px-4 py-3 text-black">
                    <JourneySummary stages={journeys.get(w.id) ?? []} />
                  </td>
                  <td className="px-4 py-3 text-black">{w.owner_name ?? DASH}</td>
                  <td className="px-4 py-3 text-black">
                    <span className={w.pending_with === 'unassigned' || w.pending_with === 'unknown'
                      ? 'text-amber-700' : ''}>{w.pending_with ?? DASH}</span>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-black">
                    {formatDate(w.stage_deadline ?? w.deadline)}
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap">
                    <span className={w.is_overdue ? 'font-medium text-red-700' : 'text-black'}>
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
