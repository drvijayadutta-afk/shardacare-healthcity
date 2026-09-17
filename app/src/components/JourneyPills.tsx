import { humanise } from '@/lib/format';

export interface JourneyStage {
  stage_id: string;
  stage_name: string;
  stage_order: number;
  track: string;
  requires_approval: boolean;
  is_terminal: boolean;
  state: 'done' | 'current' | 'upcoming';
  person_name: string | null;
  person_id: string | null;
  role_name: string | null;
  acted_at: string | null;
}

/**
 * The whole journey of a task, as pills, with the responsible person on each.
 *
 * Redesigned per the team's own description of how they read it: the 10
 * database stages collapse to the 7 steps the team actually talks about
 * (Concept and Copy are one conversation, not two; Production and Completed
 * are not worth a pill of their own), and the 4-stage purchase-order track is
 * a one-line status note — needed, raised, received — rather than its own
 * row of pills.
 *
 * Three sources of name, by position (see v_work_item_journey in 0019):
 *   done     — who actually did it
 *   current  — who holds it now
 *   upcoming — who it will route to
 *
 * Where the future routes by role rather than to a named approver, the pill
 * says the role in italics ("a designer") rather than inventing a person.
 */

/**
 * The 7 steps the team recognises, each one or more database stages folded
 * together. Legacy/alternate stage names (from the pre-0017 workflow, or
 * imported work on the old template) are included as fallbacks so a work
 * item on a different template still lands somewhere sensible instead of
 * silently disappearing.
 */
interface JourneyGroup {
  key: string;
  label: string;
  stageNames: string[];
}

/**
 * Full per-stage labels, for JourneySummary below — that view is the compact
 * one-liner used in the work list table, not the redesigned 7-step Journey
 * section, and it needs to keep showing the literal current stage (including
 * Production and Completed, which the 7-step grouping above deliberately
 * drops) so a row does not go blank while work sits in either of those.
 */
const STAGE_LABEL: Record<string, string> = {
  LEADERSHIP_BRIEF: 'Brief',
  CONCEPT: 'Concept',
  CONTENT: 'Copy',
  DESIGN: 'Design',
  CONTENT_REVIEW: 'Proofread',
  MANAGER_APPROVAL: 'Managers',
  FINAL_APPROVAL: 'Final sign-off',
  PRODUCTION: 'Production',
  RELEASE: 'Release',
  COMPLETED: 'Done',
  PO_REQUEST: 'PO raised',
  PROCUREMENT_REVIEW: 'Procurement',
  PO_APPROVAL: 'PO approval',
  PO_RELEASED: 'PO issued',
  // Pre-0015 and imported work
  IMPORTED: 'Imported',
  REQUEST: 'Request',
  BRIEF: 'Brief',
  INTERNAL_REVIEW: 'Internal review',
  DEPARTMENT_APPROVAL: 'Department',
};

function stageLabel(name: string): string {
  return STAGE_LABEL[name] ?? humanise(name);
}

const MAIN_GROUPS: JourneyGroup[] = [
  { key: 'BRIEF',         label: 'Brief',           stageNames: ['LEADERSHIP_BRIEF', 'BRIEF', 'REQUEST'] },
  { key: 'CONCEPT_COPY',  label: 'Concept & Copy',  stageNames: ['CONCEPT', 'CONTENT'] },
  { key: 'DESIGN',        label: 'Design',          stageNames: ['DESIGN'] },
  { key: 'PROOFREAD',     label: 'Proofread',       stageNames: ['CONTENT_REVIEW', 'INTERNAL_REVIEW'] },
  { key: 'MANAGERS',      label: 'Managers',        stageNames: ['MANAGER_APPROVAL', 'DEPARTMENT_APPROVAL'] },
  { key: 'FINAL_SIGNOFF', label: 'Final sign-off',  stageNames: ['FINAL_APPROVAL'] },
  { key: 'RELEASE',       label: 'Release',         stageNames: ['RELEASE'] },
];

interface GroupedStep {
  key: string;
  label: string;
  state: 'done' | 'current' | 'upcoming';
  requires_approval: boolean;
  person_name: string | null;
  role_name: string | null;
  acted_at: string | null;
  members: JourneyStage[];
}

/** Folds the raw per-stage rows into the 7 team-recognised steps. A group
 * with no matching stage on this work item's workflow is left out entirely
 * rather than rendered empty. */
function groupSteps(main: JourneyStage[]): GroupedStep[] {
  const steps: GroupedStep[] = [];

  for (const g of MAIN_GROUPS) {
    const members = g.stageNames
      .map((name) => main.find((s) => s.stage_name === name))
      .filter((s): s is JourneyStage => !!s)
      .sort((a, b) => a.stage_order - b.stage_order);

    if (!members.length) continue;

    const current = members.find((m) => m.state === 'current');
    const state: GroupedStep['state'] = current
      ? 'current'
      : members.every((m) => m.state === 'done')
        ? 'done'
        : 'upcoming';

    // The member whose name/role best represents the group's state: the one
    // actually in progress, the last one finished, or the first one still to
    // come (so an upcoming "Concept & Copy" shows who copy routes to, not a
    // stray earlier stage).
    const rep = current ?? (state === 'done' ? members[members.length - 1] : members[0]);

    steps.push({
      key: g.key,
      label: g.label,
      state,
      requires_approval: members.some((m) => m.requires_approval),
      person_name: rep.person_name,
      role_name: rep.role_name,
      acted_at: rep.acted_at,
      members,
    });
  }

  return steps;
}

const ROLE_LABEL: Record<string, string> = {
  CONTENT_WRITER: 'content writer',
  DESIGNER: 'designer',
  SOCIAL_MEDIA: 'social media',
  MANAGER: 'manager',
  FINAL_APPROVER: 'final approver',
  APPROVER: 'approver',
  COORDINATOR: 'coordinator',
  CREATOR: 'creator',
  REQUESTOR: 'requestor',
  VENDOR: 'vendor',
  ADMIN: 'admin',
  WORKFLOW_MANAGER: 'workflow manager',
  STATUS_CONTROLLER: 'controller',
  VIDEO_EDITOR: 'video editor',
};

/** First name only. The pills are narrow and the team is nine people. */
function shortName(full: string): string {
  const first = full.trim().split(/\s+/)[0];
  return first.length > 14 ? `${first.slice(0, 13)}…` : first;
}

function whoLabel(step: Pick<GroupedStep, 'state' | 'person_name' | 'role_name'>): { text: string; muted: boolean } | null {
  if (step.person_name) return { text: shortName(step.person_name), muted: false };

  // A stage already PASSED with nobody named should not be papered over with
  // "a designer" — that would say a designer did it when the record shows
  // nobody was written down. Imported work is full of exactly this case.
  if (step.state === 'done') return { text: 'not recorded', muted: true };

  if (step.role_name) {
    const label = ROLE_LABEL[step.role_name] ?? humanise(step.role_name).toLowerCase();
    return { text: `a ${label}`, muted: true };
  }
  return { text: 'unassigned', muted: true };
}

function Pill({ step }: { step: GroupedStep }) {
  const who = whoLabel(step);

  const shell =
    step.state === 'current'
      ? 'bg-brand-navy text-white ring-brand-navy'
      : step.state === 'done'
        ? 'bg-emerald-50 text-emerald-900 ring-emerald-200'
        : 'bg-white text-black ring-slate-200';

  const nameTone =
    step.state === 'current'
      ? who?.muted ? 'text-white/60 italic' : 'text-white/90'
      : step.state === 'done'
        ? who?.muted ? 'text-emerald-700/60 italic' : 'text-emerald-700'
        : who?.muted ? 'text-black italic' : 'text-black';

  // The tooltip names the actual database stage(s) behind this pill, since
  // "Concept & Copy" is two stages folded into one and a hover is where that
  // detail belongs.
  const stageNames = step.members.map((m) => humanise(m.stage_name)).join(' + ');
  const title = [
    stageNames !== step.label ? stageNames : null,
    step.person_name ?? (step.role_name ? `routes to a ${ROLE_LABEL[step.role_name] ?? step.role_name}` : null),
    step.acted_at ? new Date(step.acted_at).toLocaleString('en-GB') : null,
    step.requires_approval ? 'Approval gate' : null,
  ].filter(Boolean).join(' · ');

  return (
    <span
      aria-current={step.state === 'current' ? 'step' : undefined}
      title={title}
      className={`inline-flex shrink-0 items-center gap-1.5 rounded-full py-1 pl-2.5 pr-3
                  text-xs ring-1 ring-inset ${shell}`}
    >
      {step.state === 'done' && <span aria-hidden className="text-emerald-600">✓</span>}
      {step.requires_approval && step.state !== 'done' && (
        <span aria-hidden className="opacity-60" title="Approval gate">⚑</span>
      )}
      <span className="font-medium">{step.label}</span>
      {who && (
        <>
          <span aria-hidden className={step.state === 'current' ? 'text-white/30' : 'text-slate-300'}>
            ·
          </span>
          <span className={nameTone}>{who.text}</span>
        </>
      )}
    </span>
  );
}

/** "needed", "raised", "received" — the three facts the team actually tracks
 * about a purchase order, replacing the old 4-pill PO_REQUEST → PO_RELEASED
 * rail with one line. v_work_item_journey only returns PO-track rows at all
 * when the work item needs one, so an empty array reliably means "not
 * needed" rather than "no data yet". */
function PoStatusNote({ po }: { po: JourneyStage[] }) {
  if (po.length === 0) {
    return (
      <p className="text-xs text-black">
        <span className="font-medium">Purchase order</span> — not needed
      </p>
    );
  }

  const byName = new Map(po.map((s) => [s.stage_name, s]));
  const raised = byName.get('PO_REQUEST')?.state === 'done';
  const received = byName.get('PO_RELEASED')?.state === 'done';

  return (
    <p className="text-xs text-black">
      <span className="font-medium">Purchase order</span> — needed,{' '}
      <span className={raised ? 'text-emerald-700' : 'italic text-black'}>
        {raised ? 'raised' : 'not yet raised'}
      </span>
      {', '}
      <span className={received ? 'text-emerald-700' : 'italic text-black'}>
        {received ? 'received' : 'not yet received'}
      </span>
    </p>
  );
}

export function JourneyPills({ stages }: { stages: JourneyStage[] }) {
  const main = stages.filter((s) => s.track === 'MAIN').sort((a, b) => a.stage_order - b.stage_order);
  const po = stages.filter((s) => s.track === 'PO').sort((a, b) => a.stage_order - b.stage_order);
  const steps = groupSteps(main);

  if (!steps.length) {
    return <p className="mt-3 text-sm text-black">No workflow configured for this work.</p>;
  }

  return (
    <div className="mt-3 space-y-2">
      {/*
        Wraps rather than scrolls. A horizontal rail looked tidier but clipped
        the last few steps on a laptop and hid them behind a swipe on a
        phone — which is exactly the thing this view exists to prevent. The
        arrows carry the sequence across the line break.
      */}
      <ol className="flex list-none flex-wrap items-center gap-x-1 gap-y-1.5">
        {steps.map((step, i) => (
          <li key={step.key} className="flex shrink-0 items-center gap-1">
            {i > 0 && <span aria-hidden className="text-slate-300">→</span>}
            <Pill step={step} />
          </li>
        ))}
      </ol>

      <PoStatusNote po={po} />
    </div>
  );
}

/**
 * The same journey compressed to one line for the work list, where a full
 * chain per row would bury the table. Shows what is done, who has it now, and
 * who is next — which is the whole story at a glance.
 */
export function JourneySummary({ stages }: { stages: JourneyStage[] }) {
  const main = stages
    .filter((s) => s.track === 'MAIN')
    .sort((a, b) => a.stage_order - b.stage_order);

  const current = main.find((s) => s.state === 'current');
  const next = main.find((s) => s.stage_order > (current?.stage_order ?? -1) && s.state === 'upcoming');
  const doneCount = main.filter((s) => s.state === 'done').length;

  if (!current) return null;

  return (
    <span className="inline-flex flex-wrap items-center gap-1.5 text-xs">
      <span className="text-black">{doneCount}/{main.length}</span>
      <span className="inline-flex items-center gap-1 rounded-full bg-brand-navy py-0.5 pl-2 pr-2.5 text-white">
        <span className="font-medium">{stageLabel(current.stage_name)}</span>
        {whoLabel(current) && (
          <span className="text-white/70">{whoLabel(current)!.text}</span>
        )}
      </span>
      {next && (
        <>
          <span aria-hidden className="text-slate-300">→</span>
          <span className="text-black">
            {stageLabel(next.stage_name)}{' '}
            <span className="text-black">{whoLabel(next)?.text}</span>
          </span>
        </>
      )}
    </span>
  );
}
