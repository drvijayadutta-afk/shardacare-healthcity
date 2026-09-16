import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { getCurrentUser, canViewAllWork, canCreateWork } from '@/lib/auth/roles';
import { StatusBadge, PriorityBadge, StageBadge } from '@/components/Badges';
import { TeamRoster, type RosterPerson } from '@/components/TeamRoster';
import { formatDate, formatDaysRemaining, humanise, actionLabel, DASH } from '@/lib/format';

export const dynamic = 'force-dynamic';

interface Metrics {
  active: number; due_today: number; due_this_week: number; overdue: number;
  awaiting_approval: number; po_pending: number; blocked: number; completed: number;
  needs_review: number; unassigned: number;
}

/** A headline number. Always a link, so every figure can be opened. */
function Tile({ label, value, filter, tone = 'default' }: {
  label: string; value: number; filter: string;
  tone?: 'default' | 'warn' | 'bad' | 'good';
}) {
  const tones = {
    default: 'text-black',
    warn:    'text-amber-700',
    bad:     value > 0 ? 'text-red-700' : 'text-black',
    good:    'text-emerald-700',
  };
  return (
    <Link href={`/work?filter=${filter}`}
      className="rounded-lg border border-slate-200 bg-white p-4 transition hover:border-slate-400 hover:shadow-sm">
      <div className={`text-2xl font-semibold tabular-nums ${tones[tone]}`}>{value}</div>
      <div className="mt-0.5 text-xs font-medium text-black">{label}</div>
    </Link>
  );
}

function Panel({ title, subtitle, children }: {
  title: string; subtitle?: string; children: React.ReactNode;
}) {
  return (
    <section className="rounded-lg border border-slate-200 bg-white p-5">
      <h2 className="text-sm font-semibold text-black">{title}</h2>
      {subtitle && <p className="mt-0.5 text-xs text-black">{subtitle}</p>}
      <div className="mt-3">{children}</div>
    </section>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return <p className="text-sm text-black">{children}</p>;
}

export default async function ControlTowerPage() {
  const user = await getCurrentUser();

  // RLS narrows these aggregates to whatever the caller may see. For a creator
  // that is their own work only, which would make every total quietly mean
  // something different rather than simply being empty — so this is a
  // management view or nothing.
  if (!canViewAllWork(user)) {
    redirect('/my-work');
  }

  const supabase = await createClient();

  const [metricsRes, byStage, byOwner, approvals, poBlocks, critical, upcoming] =
    await Promise.all([
      supabase.rpc('get_control_tower_metrics'),
      supabase.rpc('get_work_by_stage'),
      supabase.rpc('get_work_by_owner'),
      supabase.rpc('get_approval_bottlenecks'),
      supabase.rpc('get_po_bottlenecks'),
      supabase.from('v_work_items').select('*')
        .eq('priority', 'CRITICAL')
        .not('status', 'in', '(COMPLETED,CANCELLED,REJECTED)')
        .order('stage_deadline', { ascending: true, nullsFirst: false }).limit(10),
      supabase.from('v_work_items').select('*')
        .not('status', 'in', '(COMPLETED,CANCELLED,REJECTED)')
        .not('stage_deadline', 'is', null)
        .gte('stage_deadline', new Date().toISOString().slice(0, 10))
        .order('stage_deadline', { ascending: true }).limit(10),
    ]);

  // A manager's own queue belongs on the same page as everyone else's. Having
  // to switch to My Work to see it makes this a report rather than a console.
  const mine = await supabase.from('v_my_tasks').select('*')
    .order('effective_due_date', { ascending: true, nullsFirst: false });

  const roster = await supabase.from('users')
    .select('id, full_name, user_roles(roles(name))')
    .eq('is_active', true).order('full_name');

  // Every query is checked, not just the metrics one. A failing breakdown RPC
  // returns no rows, which would otherwise render as the panel's empty state --
  // a dashboard confidently reporting "No open work" when it actually failed to
  // ask. An empty panel must only ever mean a genuine zero-row result.
  const failures = (
    [
      ['get_control_tower_metrics', metricsRes.error],
      ['get_work_by_stage', byStage.error],
      ['get_work_by_owner', byOwner.error],
      ['get_approval_bottlenecks', approvals.error],
      ['get_po_bottlenecks', poBlocks.error],
      ['critical work query', critical.error],
      ['upcoming deadlines query', upcoming.error],
      ['your queue', mine.error],
    ] as const
  ).filter(([, err]) => err);

  if (failures.length > 0) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-4">
        <h1 className="font-medium text-red-800">
          Could not load the Control Tower
        </h1>
        <p className="mt-2 text-sm text-red-700">
          Showing an error rather than zeroes, because a dashboard that reports
          &ldquo;no work&rdquo; when it failed to ask is worse than one that
          refuses to render.
        </p>
        <ul className="mt-3 space-y-1 text-sm text-red-700">
          {failures.map(([name, err]) => (
            <li key={name}>
              <span className="font-mono text-xs">{name}</span> — {err!.message}
            </li>
          ))}
        </ul>
        <p className="mt-3 text-xs text-red-600">
          If these name missing functions, the schema is not fully applied. Run
          database/supabase-bundle/01_schema.sql in the Supabase SQL editor.
        </p>
      </div>
    );
  }

  const m = metricsRes.data as Metrics;

  type RosterRow = { id: string; full_name: string; user_roles: { roles: { name: string } | null }[] };
  const rosterPeople: RosterPerson[] = ((roster.data ?? []) as unknown as RosterRow[]).map((u) => ({
    id: u.id,
    full_name: u.full_name,
    roles: (u.user_roles ?? []).map((r) => r.roles?.name).filter(Boolean) as string[],
  }));

  return (
    <div className="lg:grid lg:grid-cols-[1fr_260px] lg:items-start lg:gap-5">
    <div className="space-y-5">
      <div>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold text-black">Control Tower</h1>
            <p className="mt-1 text-sm text-black">
              Every number is a live count. Click one to open exactly those items.
            </p>
          </div>
          {canCreateWork(user) && (
            <Link href="/work/new"
              className="rounded-md bg-brand-navy px-3 py-2 text-sm font-medium text-white hover:bg-brand-navy-dark">
              Add work
            </Link>
          )}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Tile label="Active Work"       value={m.active}            filter="active" />
        <Tile label="Due Today"         value={m.due_today}         filter="due_today" tone="warn" />
        <Tile label="Due This Week"     value={m.due_this_week}     filter="due_this_week" />
        <Tile label="Overdue"           value={m.overdue}           filter="overdue" tone="bad" />
        <Tile label="Awaiting Approval" value={m.awaiting_approval} filter="awaiting_approval" tone="warn" />
        <Tile label="PO Pending"        value={m.po_pending}        filter="po_pending" tone="warn" />
        <Tile label="Blocked"           value={m.blocked}           filter="blocked" tone="bad" />
        <Tile label="Completed"         value={m.completed}         filter="completed" tone="good" />
      </div>

      {(m.needs_review > 0 || m.unassigned > 0) && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {m.needs_review > 0 && (
            <Tile label="Needs Review (imported)" value={m.needs_review} filter="needs_review" tone="warn" />
          )}
          {m.unassigned > 0 && (
            <Tile label="Nobody Assigned" value={m.unassigned} filter="unassigned" tone="warn" />
          )}
        </div>
      )}

      <Panel
        title="Your queue"
        subtitle={
          mine.data?.length
            ? 'Assigned to you — act on these'
            : 'Nothing is assigned to you right now'
        }
      >
        {mine.data?.length ? (
          <ul className="divide-y divide-slate-100">
            {mine.data.map((t) => (
              <li key={t.task_id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-sm">
                <Link href={`/work/${t.work_item_id}`}
                  className="font-medium text-black underline-offset-2 hover:underline">
                  {t.work_name}
                </Link>
                <StageBadge stage={t.stage_name} />
                <span className="text-black">{actionLabel(t.action_type)}</span>
                <span className={`ml-auto ${t.is_overdue ? 'font-medium text-red-700' : 'text-black'}`}>
                  {formatDaysRemaining(t.days_remaining)}
                </span>
                <PriorityBadge priority={t.task_priority} />
              </li>
            ))}
          </ul>
        ) : (
          <Empty>
            Work lands here when someone hands it to you. Everything below is the
            team&rsquo;s.
          </Empty>
        )}
      </Panel>

      <Panel title="Critical work"
             subtitle="Highest priority, still open">
        {critical.data?.length ? (
          <ul className="divide-y divide-slate-100">
            {critical.data.map((w) => (
              <li key={w.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-sm">
                <Link href={`/work/${w.id}`}
                  className="font-medium text-black underline-offset-2 hover:underline">
                  {w.name}
                </Link>
                <StageBadge stage={w.stage_name} />
                <span className="text-black">{w.pending_with ?? DASH}</span>
                <span className={`ml-auto ${w.is_overdue ? 'font-medium text-red-700' : 'text-black'}`}>
                  {formatDaysRemaining(w.days_remaining)}
                </span>
                <StatusBadge status={w.status} />
              </li>
            ))}
          </ul>
        ) : <Empty>No critical work open.</Empty>}
      </Panel>

      <div className="grid gap-5 lg:grid-cols-2">
        <Panel title="Work by stage" subtitle="Where open work is sitting">
          {byStage.data?.length ? (
            <ul className="space-y-1.5">
              {byStage.data.map((r: { stage_name: string; work_count: number }) => {
                const max = Math.max(...byStage.data.map((x: { work_count: number }) => Number(x.work_count)));
                const pct = Math.round((Number(r.work_count) / max) * 100);
                return (
                  <li key={r.stage_name} className="flex items-center gap-3 text-sm">
                    <span className="w-40 shrink-0 truncate"><StageBadge stage={r.stage_name} /></span>
                    <span className="h-2 flex-1 overflow-hidden rounded-full bg-slate-100">
                      <span className="block h-full rounded-full bg-slate-400"
                            style={{ width: `${pct}%` }} />
                    </span>
                    <span className="w-8 text-right tabular-nums text-black">{r.work_count}</span>
                  </li>
                );
              })}
            </ul>
          ) : <Empty>No open work.</Empty>}
        </Panel>

        <Panel title="Work by owner" subtitle="Who is carrying what">
          {byOwner.data?.length ? (
            <ul className="divide-y divide-slate-100">
              {byOwner.data.slice(0, 12).map(
                (r: { owner_name: string; owner_id: string | null; work_count: number; overdue_count: number }) => (
                <li key={r.owner_name} className="flex items-center gap-3 py-1.5 text-sm">
                  {r.owner_id ? (
                    <Link
                      href={`/work?filter=active&owner=${r.owner_id}&name=${encodeURIComponent(r.owner_name)}`}
                      className="flex-1 truncate text-black underline-offset-2 hover:underline">
                      {r.owner_name}
                    </Link>
                  ) : (
                    <Link href="/work?filter=unassigned"
                      className="flex-1 truncate text-amber-700 underline-offset-2 hover:underline">
                      {r.owner_name}
                    </Link>
                  )}
                  {Number(r.overdue_count) > 0 && (
                    <span className="text-xs font-medium text-red-700">
                      {r.overdue_count} overdue
                    </span>
                  )}
                  <span className="w-8 text-right tabular-nums text-black">{r.work_count}</span>
                </li>
              ))}
            </ul>
          ) : <Empty>No open work.</Empty>}
        </Panel>

        <Panel title="Approval bottlenecks"
               subtitle="Waiting at an approval gate, longest first">
          {approvals.data?.length ? (
            <ul className="divide-y divide-slate-100">
              {approvals.data.map(
                (r: { pending_with: string; work_count: number; oldest_days: number; overdue_count: number }) => (
                <li key={r.pending_with} className="flex items-center gap-3 py-1.5 text-sm">
                  <span className={`flex-1 truncate ${
                    r.pending_with === 'Unassigned' || r.pending_with === 'unknown'
                      ? 'text-amber-700' : 'text-black'}`}>
                    {r.pending_with}
                  </span>
                  {r.oldest_days > 0 && (
                    <span className="text-xs text-black">
                      waiting {r.oldest_days}d
                    </span>
                  )}
                  <span className="w-8 text-right tabular-nums text-black">{r.work_count}</span>
                </li>
              ))}
            </ul>
          ) : <Empty>Nothing waiting on approval.</Empty>}
        </Panel>

        <Panel title="PO bottlenecks" subtitle="Procurement not yet released">
          {poBlocks.data?.length ? (
            <ul className="divide-y divide-slate-100">
              {poBlocks.data.map((r: { po_status: string; work_count: number; overdue_count: number }) => (
                <li key={r.po_status} className="flex items-center gap-3 py-1.5 text-sm">
                  <span className="flex-1 text-black">{humanise(r.po_status)}</span>
                  {Number(r.overdue_count) > 0 && (
                    <span className="text-xs font-medium text-red-700">{r.overdue_count} overdue</span>
                  )}
                  <span className="w-8 text-right tabular-nums text-black">{r.work_count}</span>
                </li>
              ))}
            </ul>
          ) : <Empty>No purchase orders outstanding.</Empty>}
        </Panel>
      </div>

      <Panel title="Upcoming deadlines" subtitle="Next ten, soonest first">
        {upcoming.data?.length ? (
          <ul className="divide-y divide-slate-100">
            {upcoming.data.map((w) => (
              <li key={w.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-sm">
                <Link href={`/work/${w.id}`}
                  className="font-medium text-black underline-offset-2 hover:underline">
                  {w.name}
                </Link>
                <span className="text-black">{w.pending_with ?? DASH}</span>
                <PriorityBadge priority={w.priority} />
                <span className="ml-auto whitespace-nowrap text-black">
                  {formatDate(w.stage_deadline)}
                </span>
                <span className="w-20 text-right text-black">
                  {formatDaysRemaining(w.days_remaining)}
                </span>
              </li>
            ))}
          </ul>
        ) : (
          <Empty>
            No upcoming deadlines. 20 of the imported items have no date in the
            source document, so they cannot appear here.
          </Empty>
        )}
      </Panel>
    </div>

    <div className="mt-5 lg:mt-0">
      {roster.error ? (
        <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">
          Could not load the team list — {roster.error.message}
        </div>
      ) : (
        <TeamRoster people={rosterPeople} />
      )}
    </div>
    </div>
  );
}
