import Link from 'next/link';
import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { getCurrentUser, hasPermission, hasRole } from '@/lib/auth/roles';
import { StatusBadge, PriorityBadge, OverdueBadge, StageBadge } from '@/components/Badges';
import { WorkActions } from '@/components/WorkActions';
import { AdminControls } from '@/components/AdminControls';
import { JourneyPills, type JourneyStage } from '@/components/JourneyPills';
import { CommentThread, type CommentRow } from '@/components/CommentThread';
import { FileUpload } from '@/components/FileUpload';
import { FileList, type AttachedFile } from '@/components/FileList';
import { TagEditor, type WorkTag } from '@/components/TagEditor';
import { PoTrack, type PoStep, type PoDetails } from '@/components/PoTrack';
import { formatDate, formatDaysRemaining, humanise, DASH } from '@/lib/format';

export const dynamic = 'force-dynamic';

/** Supabase returns an embedded one-to-one as an object; the generated type says array. */
function nameOf(rel: unknown): string | null {
  const r = rel as { full_name?: string } | null;
  return r?.full_name ?? null;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-black">{label}</dt>
      <dd className="mt-0.5 text-sm text-black">{children}</dd>
    </div>
  );
}

function Section({ title, count, children }: {
  title: string; count?: number; children: React.ReactNode;
}) {
  return (
    <section className="rounded-lg border border-slate-200 bg-white p-5">
      <h2 className="text-sm font-semibold text-black">
        {title}
        {count !== undefined && <span className="ml-1.5 font-normal text-black">{count}</span>}
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

  const [journey, files, comments, activity, myTask, owners, tags, poSteps, po] =
    await Promise.all([
      supabase.from('v_work_item_journey')
        .select('stage_id, stage_name, stage_order, track, requires_approval, is_terminal, state, person_name, person_id, role_name, acted_at')
        .eq('work_item_id', id).order('stage_order'),
      supabase.from('files')
        .select('id, file_name, mime_type, size_bytes, uploaded_at, uploaded_by, users:uploaded_by(full_name)')
        .eq('work_item_id', id).is('deleted_at', null).order('uploaded_at', { ascending: false }),
      supabase.from('comments')
        .select('id, body, comment_type, created_at, parent_id, is_resolved, deleted_at, author_id, users:author_id(full_name)')
        .eq('work_item_id', id).order('created_at', { ascending: false }),
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
      supabase.from('v_work_item_tags')
        .select('tag_id, slug, label, colour').eq('work_item_id', id),
      supabase.from('v_po_track')
        .select('step_order, code, label, state').eq('work_item_id', id).order('step_order'),
      work.po_request_id
        ? supabase.from('po_requests')
            .select('id, po_number, vendor_name, amount, currency, description, status')
            .eq('id', work.po_request_id).maybeSingle()
        : Promise.resolve({ data: null }),
    ]);

  // What this viewer may do. Presentation only — the database re-checks on
  // every write, so hiding a button is a convenience, not the boundary.
  const holdsIt =
    !!myTask.data ||
    work.current_assignee_id === user?.id ||
    work.owner_id === user?.id;
  const isFinished = ['COMPLETED', 'CANCELLED', 'REJECTED'].includes(work.status);
  const isOnHold = work.status === 'ON_HOLD';

  // Moving work between stages is reserved (migration 0015). Everyone else can
  // still attach, tag and comment — which is most of what a day involves.
  const canChangeStatus = hasPermission(user, 'change_status');
  const canModerate = hasRole(user, 'ADMIN', 'WORKFLOW_MANAGER', 'MANAGER');

  const canApprove = canChangeStatus && holdsIt && work.stage_requires_approval && !isFinished && !isOnHold;
  const canSubmit  = canChangeStatus && holdsIt && !isFinished && !isOnHold;
  const canHold    = canChangeStatus && holdsIt && !isFinished;

  // Admin override — distinct from the normal submit/approve/hold flow
  // above (which is for whoever holds the work). This is the ability to
  // add a task, reassign work off someone else entirely, or delete a task
  // outright — restricted to exactly the STATUS_CONTROLLER role (Nirmal and
  // Vijaya) plus ADMIN (0026), reusing the same canChangeStatus computed
  // above rather than a role list, since that IS the same permission —
  // "controls the to-do list" and "controls moving work between stages" are
  // the same reserved capability, not two separate ones. Same check as
  // reassign_work_item / remove_task / add_task_to_work_item themselves
  // (0013, narrowed in 0026) — this only decides whether the panel renders.
  const canManage = canChangeStatus && !isFinished && !isOnHold;
  const canDelete = canChangeStatus;

  let adminPeople: { id: string; full_name: string }[] = [];
  let currentTaskId: string | null = null;
  let currentAssigneeNameForTask: string | null = null;

  if (canManage && work.current_stage_id) {
    const [peopleRes, taskRes] = await Promise.all([
      supabase.from('users').select('id, full_name').eq('is_active', true).order('full_name'),
      supabase.from('tasks')
        .select('id, users:assignee_id(full_name)')
        .eq('work_item_id', id).eq('stage_id', work.current_stage_id)
        .is('closed_at', null).maybeSingle(),
    ]);
    adminPeople = peopleRes.data ?? [];
    currentTaskId = taskRes.data?.id ?? null;
    currentAssigneeNameForTask =
      (taskRes.data?.users as unknown as { full_name: string } | null)?.full_name ?? null;
  }

  const fileRows: AttachedFile[] = (files.data ?? []).map((f) => ({
    id: f.id,
    file_name: f.file_name,
    mime_type: f.mime_type,
    size_bytes: f.size_bytes,
    uploaded_at: f.uploaded_at,
    uploader: nameOf(f.users),
    is_mine: f.uploaded_by === user?.id,
  }));

  const commentRows: CommentRow[] = (comments.data ?? []).map((c) => ({
    id: c.id,
    body: c.body,
    comment_type: c.comment_type,
    created_at: c.created_at,
    parent_id: c.parent_id,
    is_resolved: c.is_resolved,
    deleted_at: c.deleted_at,
    author: nameOf(c.users),
    is_mine: c.author_id === user?.id,
  }));

  const openComments = commentRows.filter((c) => !c.parent_id && !c.is_resolved && !c.deleted_at).length;

  return (
    <div className="space-y-5">
      <div>
        <Link href="/my-work" className="text-sm text-black hover:text-black">
          ← My Work
        </Link>
        <div className="mt-2 flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold text-black">{work.name}</h1>
            <p className="mt-1 text-sm text-black">
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
          <h2 className="text-sm font-medium text-black">
            On hold — {humanise(work.blocker_type)}
          </h2>
          <p className="mt-1 text-sm text-black">{work.blocker_note}</p>
        </div>
      )}

      <Section title="Work information">
        <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-3 lg:grid-cols-4">
          <Field label="Current Stage"><StageBadge stage={work.stage_name} /></Field>
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
            {work.po_status === 'NOT_ASSESSED'
              ? <span className="text-amber-700">Not assessed — source did not say</span>
              : work.po_required ? humanise(work.po_status) : 'Not required'}
          </Field>
          <Field label="Collaborators">
            {owners.data?.length
              ? owners.data.map((o) => nameOf(o.users)).filter(Boolean).join(', ')
              : DASH}
          </Field>
        </dl>
        {work.description && (
          <p className="mt-4 border-t border-slate-100 pt-4 text-sm text-black">
            {work.description}
          </p>
        )}
      </Section>

      <Section title="Tags" count={tags.data?.length ?? 0}>
        <TagEditor
          workItemId={id}
          tags={(tags.data ?? []) as WorkTag[]}
          canEdit={!isFinished}
        />
      </Section>

      <Section title="Journey">
        <JourneyPills stages={(journey.data ?? []) as JourneyStage[]} />
      </Section>

      <div className="grid gap-5 lg:grid-cols-2">
        <Section title="Purchase order">
          <PoTrack
            workItemId={id}
            poRequired={work.po_required}
            poStatus={work.po_status}
            steps={(poSteps.data ?? []) as PoStep[]}
            po={(po.data ?? null) as PoDetails | null}
            canChangeStatus={canChangeStatus}
            blocksRelease={work.po_required}
          />
        </Section>

        <Section title="Actions">
          <div className="mt-3">
            {canChangeStatus ? (
              <WorkActions
                workItemId={id}
                canSubmit={canSubmit}
                canApprove={canApprove}
                canHold={canHold}
                isOnHold={isOnHold}
              />
            ) : (
              <p className="text-sm text-black">
                Only Vijaya and Nirmal can move work between stages. You can attach
                files, add tags and comment here.
              </p>
            )}
          </div>
        </Section>
      </div>

      {canManage && (
        <Section title="Admin controls">
          <div className="mt-3">
            <AdminControls
              workItemId={id}
              people={adminPeople}
              currentTaskId={currentTaskId}
              currentAssigneeName={currentAssigneeNameForTask ?? work.owner_name}
              canDelete={canDelete}
            />
          </div>
        </Section>
      )}

      <div className="grid gap-5 lg:grid-cols-2">
        <Section title="Files" count={fileRows.length}>
          <FileList workItemId={id} files={fileRows} canRemoveAny={canModerate} />
          {!isFinished && <FileUpload workItemId={id} />}
        </Section>

        <Section title="Comments" count={openComments}>
          <CommentThread
            workItemId={id}
            comments={commentRows}
            canModerate={canModerate}
          />
        </Section>
      </div>

      <Section title="Activity history" count={activity.data?.length ?? 0}>
        {activity.data?.length ? (
          <ol className="mt-3 divide-y divide-slate-100">
            {activity.data.map((a) => (
              <li key={a.id} className="flex flex-wrap items-baseline gap-x-2 py-2 text-sm">
                <span className="font-medium text-black">{humanise(a.action)}</span>
                {a.from_value && a.to_value && (
                  <span className="text-black">
                    {humanise(a.from_value)} → {humanise(a.to_value)}
                  </span>
                )}
                {!a.from_value && a.to_value && (
                  <span className="text-black">{humanise(a.to_value)}</span>
                )}
                <span className="text-black">
                  by {nameOf(a.users) ?? 'system'}
                </span>
                <span className="ml-auto whitespace-nowrap text-xs text-black">
                  {new Date(a.occurred_at).toLocaleString('en-GB')}
                </span>
              </li>
            ))}
          </ol>
        ) : (
          <p className="mt-3 text-sm text-black">Nothing has happened yet.</p>
        )}
      </Section>
    </div>
  );
}
