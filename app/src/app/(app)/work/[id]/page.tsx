import Link from 'next/link';
import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { getCurrentUser } from '@/lib/auth/roles';
import { StatusBadge, PriorityBadge, OverdueBadge } from '@/components/Badges';
import { WorkActions } from '@/components/WorkActions';
import { WorkflowStepper } from '@/components/WorkflowStepper';
import { CommentForm } from '@/components/CommentForm';
import { formatDate, formatDaysRemaining, humanise, DASH } from '@/lib/format';

export const dynamic = 'force-dynamic';

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</dt>
      <dd className="mt-0.5 text-sm text-slate-900">{children}</dd>
    </div>
  );
}

function Section({ title, count, children }: {
  title: string; count?: number; children: React.ReactNode;
}) {
  return (
    <section className="rounded-lg border border-slate-200 bg-white p-5">
      <h2 className="text-sm font-semibold text-slate-900">
        {title}
        {count !== undefined && <span className="ml-1.5 font-normal text-slate-400">{count}</span>}
      </h2>
      {children}
    </section>
  );
}

export default async function WorkDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const user = await getCurrentUser();

  const { data: work } = await supabase
    .from('v_work_items').select('*').eq('id', id).maybeSingle();

  // RLS returns nothing rather than an error for work you may not see, so an
  // empty result means "not found or not yours" — both are a 404 to the user.
  if (!work) notFound();

  const [stages, files, comments, activity, myTask, owners] = await Promise.all([
    supabase.from('workflow_stages')
      .select('id, name, stage_order, requires_approval')
      .eq('workflow_id', work.workflow_id).order('stage_order'),
    supabase.from('files')
      .select('id, file_name, file_type, size_bytes, uploaded_at, users:uploaded_by(full_name)')
      .eq('work_item_id', id).is('deleted_at', null).order('uploaded_at', { ascending: false }),
    supabase.from('comments')
      .select('id, body, comment_type, created_at, users:author_id(full_name)')
      .eq('work_item_id', id).is('deleted_at', null).order('created_at', { ascending: false }),
    // Rows written inside one handoff share a timestamp, so id is the
    // tiebreaker — without it the history reshuffles between page loads.
    supabase.from('activity_log')
      .select('id, action, from_value, to_value, occurred_at, users:actor_id(full_name)')
      .eq('work_item_id', id)
      .order('occurred_at', { ascending: false }).order('id', { ascending: false }).limit(50),
    supabase.from('tasks')
      .select('id, action_type').eq('work_item_id', id)
      .eq('assignee_id', user?.id ?? '').is('closed_at', null).maybeSingle(),
    supabase.from('work_item_owners')
      .select('owner_role, users:user_id(full_name)').eq('work_item_id', id),
  ]);

  // What this viewer may do. Presentation only — submit_for_next_stage re-checks
  // and RLS enforces, so hiding a button is a convenience, not the boundary.
  const holdsIt =
    !!myTask.data ||
    work.current_assignee_id === user?.id ||
    work.owner_id === user?.id;
  const isFinished = ['COMPLETED', 'CANCELLED', 'REJECTED'].includes(work.status);
  const isOnHold = work.status === 'ON_HOLD';

  const canApprove = holdsIt && work.stage_requires_approval && !isFinished && !isOnHold;
  const canSubmit  = holdsIt && !isFinished && !isOnHold;
  const canHold    = holdsIt && !isFinished;

  return (
    <div className="space-y-5">
      <div>
        <Link href="/my-work" className="text-sm text-slate-500 hover:text-slate-900">
          ← My Work
        </Link>
        <div className="mt-2 flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold text-slate-900">{work.name}</h1>
            <p className="mt-1 text-sm text-slate-500">
              {work.job_name}
              {work.campaign_name && ` · ${work.campaign_name}`}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-1.5">
            <StatusBadge status={work.status} />
            <PriorityBadge priority={work.priority} />
            <OverdueBadge days={work.days_remaining} />
          </div>
        </div>
      </div>

      {work.needs_review && (
        <div className="rounded-md border border-amber-200 bg-amber-50 p-4">
          <h2 className="text-sm font-medium text-amber-900">Imported — needs review</h2>
          <p className="mt-1 text-sm text-amber-800">{work.review_notes}</p>
          {work.source_text && (
            <p className="mt-2 text-xs text-amber-700">
              Original line: <span className="font-mono">{work.source_text}</span>
            </p>
          )}
        </div>
      )}

      {isOnHold && work.blocker_note && (
        <div className="rounded-md border border-slate-300 bg-slate-100 p-4">
          <h2 className="text-sm font-medium text-slate-900">
            On hold — {humanise(work.blocker_type)}
          </h2>
          <p className="mt-1 text-sm text-slate-700">{work.blocker_note}</p>
        </div>
      )}

      <Section title="Work information">
        <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-3 lg:grid-cols-4">
          <Field label="Current Stage">{humanise(work.stage_name)}</Field>
          <Field label="Current Owner">{work.owner_name ?? DASH}</Field>
          <Field label="Pending With">
            {work.pending_with
              ? <span className={work.pending_with === 'unassigned' || work.pending_with === 'unknown'
                  ? 'text-amber-700' : ''}>{work.pending_with}</span>
              : DASH}
          </Field>
          <Field label="Deadline">{formatDate(work.stage_deadline ?? work.deadline)}</Field>
          <Field label="Days Remaining">
            <span className={work.is_overdue ? 'font-medium text-red-700' : ''}>
              {formatDaysRemaining(work.days_remaining)}
            </span>
          </Field>
          <Field label="Approval">
            {work.approval_required ? humanise(work.approval_status) : 'Not required'}
          </Field>
          <Field label="Purchase Order">
            {work.po_required ? humanise(work.po_status) : 'Not required'}
          </Field>
          <Field label="Collaborators">
            {owners.data?.length
              ? owners.data.map((o) =>
                  (o.users as unknown as { full_name: string } | null)?.full_name).filter(Boolean).join(', ')
              : DASH}
          </Field>
        </dl>
        {work.description && (
          <p className="mt-4 border-t border-slate-100 pt-4 text-sm text-slate-700">
            {work.description}
          </p>
        )}
      </Section>

      <Section title="Workflow progress">
        <div className="mt-3">
          <WorkflowStepper
            stages={stages.data ?? []}
            currentOrder={work.stage_order}
            poRequired={work.po_required}
          />
        </div>
      </Section>

      <Section title="Actions">
        <div className="mt-3">
          <WorkActions
            workItemId={id}
            canSubmit={canSubmit}
            canApprove={canApprove}
            canHold={canHold}
            isOnHold={isOnHold}
          />
        </div>
      </Section>

      <div className="grid gap-5 lg:grid-cols-2">
        <Section title="Files" count={files.data?.length ?? 0}>
          {files.data?.length ? (
            <ul className="mt-3 divide-y divide-slate-100">
              {files.data.map((f) => (
                <li key={f.id} className="flex items-baseline justify-between gap-3 py-2 text-sm">
                  <span className="text-slate-900">{f.file_name}</span>
                  <span className="whitespace-nowrap text-xs text-slate-500">
                    {(f.users as unknown as { full_name: string } | null)?.full_name ?? DASH}
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="mt-3 text-sm text-slate-500">No files attached.</p>
          )}
        </Section>

        <Section title="Comments" count={comments.data?.length ?? 0}>
          {comments.data?.length ? (
            <ul className="mt-3 space-y-3">
              {comments.data.map((c) => (
                <li key={c.id} className="text-sm">
                  <div className="flex flex-wrap items-baseline gap-2">
                    <span className="font-medium text-slate-900">
                      {(c.users as unknown as { full_name: string } | null)?.full_name ?? 'Unknown'}
                    </span>
                    {c.comment_type !== 'COMMENT' && (
                      <span className="rounded bg-orange-50 px-1.5 py-0.5 text-xs text-orange-800">
                        {humanise(c.comment_type)}
                      </span>
                    )}
                    <span className="text-xs text-slate-400">
                      {new Date(c.created_at).toLocaleString('en-GB')}
                    </span>
                  </div>
                  <p className="mt-0.5 whitespace-pre-wrap text-slate-700">{c.body}</p>
                </li>
              ))}
            </ul>
          ) : (
            <p className="mt-3 text-sm text-slate-500">No comments yet.</p>
          )}
          <CommentForm workItemId={id} />
        </Section>
      </div>

      <Section title="Activity history" count={activity.data?.length ?? 0}>
        {activity.data?.length ? (
          <ol className="mt-3 divide-y divide-slate-100">
            {activity.data.map((a) => (
              <li key={a.id} className="flex flex-wrap items-baseline gap-x-2 py-2 text-sm">
                <span className="font-medium text-slate-900">{humanise(a.action)}</span>
                {a.from_value && a.to_value && (
                  <span className="text-slate-500">
                    {humanise(a.from_value)} → {humanise(a.to_value)}
                  </span>
                )}
                {!a.from_value && a.to_value && (
                  <span className="text-slate-500">{humanise(a.to_value)}</span>
                )}
                <span className="text-slate-500">
                  by {(a.users as unknown as { full_name: string } | null)?.full_name ?? 'system'}
                </span>
                <span className="ml-auto whitespace-nowrap text-xs text-slate-400">
                  {new Date(a.occurred_at).toLocaleString('en-GB')}
                </span>
              </li>
            ))}
          </ol>
        ) : (
          <p className="mt-3 text-sm text-slate-500">Nothing has happened yet.</p>
        )}
      </Section>
    </div>
  );
}
