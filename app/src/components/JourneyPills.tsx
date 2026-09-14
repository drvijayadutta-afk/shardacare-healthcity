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
 * Every stage is shown — including the ones still to come. A stepper that only
 * renders as far as the work has reached answers "where is it" but not "what
 * happens next and who do I chase", which is the question someone opens this
 * page to settle.
 *
 * Three sources of name, by position (see v_work_item_journey in 0017):
 *   done     — who actually did it
 *   current  — who holds it now
 *   upcoming — who it will route to
 *
 * Where the future routes by role rather than to a named approver, the pill
 * says the role in italics ("a designer") rather than inventing a person or
 * showing a bare dash.
 */

/**
 * What each stage is CALLED on a pill.
 *
 * Two reasons this is not just humanise(stage_name). It lowercases before
 * capitalising, so PO_REQUEST comes out as "Po request"; and the full names
 * ("Leadership brief", "Content review", "Manager approval") are long enough
 * that the ten main stages cannot fit across a laptop without being cut off —
 * and the whole point of this view is that the entire journey is visible.
 *
 * The wording follows what the team calls each step, not the database's name
 * for it: CONTENT_REVIEW is Vijaya proofreading.
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
};

/** First name only. The pills are narrow and the team is nine people. */
function shortName(full: string): string {
  const first = full.trim().split(/\s+/)[0];
  return first.length > 14 ? `${first.slice(0, 13)}…` : first;
}

function whoLabel(s: JourneyStage): { text: string; muted: boolean } | null {
  if (s.person_name) return { text: shortName(s.person_name), muted: false };

  // A terminal stage is not held by anyone — "Completed · unassigned" reads as
  // a problem when it is the happy ending.
  if (s.is_terminal) return null;

  // "a designer" is the right label for a stage still to come. On a stage
  // already PASSED it would be a small lie: it says a designer did it, when
  // what the record actually shows is that nobody was written down. Imported
  // work is full of exactly this case.
  if (s.state === 'done') return { text: 'not recorded', muted: true };

  if (s.role_name) {
    const label = ROLE_LABEL[s.role_name] ?? humanise(s.role_name).toLowerCase();
    return { text: `a ${label}`, muted: true };
  }
  return { text: 'unassigned', muted: true };
}

function Pill({ s }: { s: JourneyStage }) {
  const who = whoLabel(s);

  const shell =
    s.state === 'current'
      ? 'bg-slate-900 text-white ring-slate-900'
      : s.state === 'done'
        ? 'bg-emerald-50 text-emerald-900 ring-emerald-200'
        : 'bg-white text-black ring-slate-200';

  const nameTone =
    s.state === 'current'
      ? who?.muted ? 'text-white/60 italic' : 'text-white/90'
      : s.state === 'done'
        ? who?.muted ? 'text-emerald-700/60 italic' : 'text-emerald-700'
        : who?.muted ? 'text-black italic' : 'text-black';

  const title = [
    humanise(s.stage_name),   // the full name, for the hover
    s.person_name ?? (s.role_name ? `routes to a ${ROLE_LABEL[s.role_name] ?? s.role_name}` : null),
    s.acted_at ? new Date(s.acted_at).toLocaleString('en-GB') : null,
    s.requires_approval ? 'Approval gate' : null,
  ].filter(Boolean).join(' · ');

  return (
    <span
      aria-current={s.state === 'current' ? 'step' : undefined}
      title={title}
      className={`inline-flex shrink-0 items-center gap-1.5 rounded-full py-1 pl-2.5 pr-3
                  text-xs ring-1 ring-inset ${shell}`}
    >
      {s.state === 'done' && <span aria-hidden className="text-emerald-600">✓</span>}
      {s.requires_approval && s.state !== 'done' && (
        <span aria-hidden className="opacity-60" title="Approval gate">⚑</span>
      )}
      <span className="font-medium">{stageLabel(s.stage_name)}</span>
      {who && (
        <>
          <span aria-hidden className={s.state === 'current' ? 'text-white/30' : 'text-slate-300'}>
            ·
          </span>
          <span className={nameTone}>{who.text}</span>
        </>
      )}
    </span>
  );
}

export function JourneyPills({ stages }: { stages: JourneyStage[] }) {
  const main = stages.filter((s) => s.track === 'MAIN').sort((a, b) => a.stage_order - b.stage_order);
  const po = stages.filter((s) => s.track === 'PO').sort((a, b) => a.stage_order - b.stage_order);

  if (!main.length) {
    return <p className="mt-3 text-sm text-black">No workflow configured for this work.</p>;
  }

  return (
    <div className="mt-3 space-y-4">
      {/*
        Wraps rather than scrolls. A horizontal rail looked tidier but clipped
        the last three stages on a laptop and hid them behind a swipe on a
        phone — which is exactly the thing this view exists to prevent. The
        arrows carry the sequence across the line break.
      */}
      <ol className="flex list-none flex-wrap items-center gap-x-1 gap-y-1.5">
        {main.map((s, i) => (
          <li key={s.stage_id} className="flex shrink-0 items-center gap-1">
            {i > 0 && <span aria-hidden className="text-slate-300">→</span>}
            <Pill s={s} />
          </li>
        ))}
      </ol>

      {po.length > 0 && (
        <div>
          <p className="mb-1.5 text-xs font-medium uppercase tracking-wide text-black">
            Purchase order — runs in parallel
          </p>
          <ol className="flex list-none flex-wrap items-center gap-x-1 gap-y-1.5">
            {po.map((s, i) => (
              <li key={s.stage_id} className="flex shrink-0 items-center gap-1">
                {i > 0 && <span aria-hidden className="text-slate-300">→</span>}
                <Pill s={s} />
              </li>
            ))}
          </ol>
        </div>
      )}
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
      <span className="inline-flex items-center gap-1 rounded-full bg-slate-900 py-0.5 pl-2 pr-2.5 text-white">
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
