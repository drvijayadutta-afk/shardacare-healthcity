import { humanise } from '@/lib/format';

/**
 * Status and priority pills.
 *
 * Colour is never the only signal — each pill carries its own text, so the
 * meaning survives greyscale printing and colour-blindness.
 */

const STATUS_STYLES: Record<string, string> = {
  NOT_STARTED:      'bg-slate-100 text-black ring-slate-200',
  IN_PROGRESS:      'bg-blue-50 text-blue-700 ring-blue-200',
  SUBMITTED:        'bg-indigo-50 text-indigo-700 ring-indigo-200',
  PENDING:          'bg-amber-50 text-amber-800 ring-amber-200',
  APPROVED:         'bg-emerald-50 text-emerald-700 ring-emerald-200',
  CHANGES_REQUIRED: 'bg-orange-50 text-orange-800 ring-orange-200',
  REJECTED:         'bg-red-50 text-red-700 ring-red-200',
  BLOCKED:          'bg-red-50 text-red-700 ring-red-200',
  ON_HOLD:          'bg-slate-100 text-black ring-slate-300',
  COMPLETED:        'bg-emerald-50 text-emerald-700 ring-emerald-200',
  CANCELLED:        'bg-slate-100 text-black ring-slate-200',
};

const PRIORITY_STYLES: Record<string, string> = {
  CRITICAL: 'bg-red-50 text-red-700 ring-red-200',
  HIGH:     'bg-orange-50 text-orange-800 ring-orange-200',
  MEDIUM:   'bg-slate-100 text-black ring-slate-200',
  LOW:      'bg-slate-50 text-black ring-slate-200',
};

function Pill({ text, className }: { text: string; className: string }) {
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs
                      font-medium ring-1 ring-inset whitespace-nowrap ${className}`}>
      {text}
    </span>
  );
}

export function StatusBadge({ status }: { status: string | null }) {
  if (!status) return <span className="text-black">—</span>;
  return <Pill text={humanise(status)} className={STATUS_STYLES[status] ?? STATUS_STYLES.NOT_STARTED} />;
}

export function PriorityBadge({ priority }: { priority: string | null }) {
  if (!priority) return <span className="text-black">—</span>;
  return <Pill text={humanise(priority)} className={PRIORITY_STYLES[priority] ?? PRIORITY_STYLES.MEDIUM} />;
}

export function OverdueBadge({ days }: { days: number | null }) {
  if (days === null || days === undefined || days >= 0) return null;
  return <Pill text="Overdue" className="bg-red-50 text-red-700 ring-red-200" />;
}

/**
 * Stage colours, one per distinct stage name across whichever workflow the
 * work item is on. Stages are configuration (workflow_stages rows), not a
 * fixed set the frontend is allowed to know in advance — the Sharda flow, the
 * legacy "Imported (unclassified)" holding template and the generic default
 * workflow all have different stages. Hashing the name into a fixed palette
 * gives every distinct stage its own stable colour without hardcoding any
 * stage's name here, so a renamed or newly configured stage still gets a
 * consistent colour rather than falling back to grey.
 */
const STAGE_PALETTE = [
  'bg-blue-50 text-blue-700 ring-blue-200',
  'bg-indigo-50 text-indigo-700 ring-indigo-200',
  'bg-violet-50 text-violet-700 ring-violet-200',
  'bg-fuchsia-50 text-fuchsia-700 ring-fuchsia-200',
  'bg-teal-50 text-teal-700 ring-teal-200',
  'bg-cyan-50 text-cyan-700 ring-cyan-200',
  'bg-purple-50 text-purple-700 ring-purple-200',
  'bg-sky-50 text-sky-700 ring-sky-200',
  'bg-lime-50 text-lime-800 ring-lime-200',
  'bg-pink-50 text-pink-700 ring-pink-200',
] as const;

function stageStyle(stageName: string): string {
  let hash = 0;
  for (let i = 0; i < stageName.length; i++) {
    hash = (hash * 31 + stageName.charCodeAt(i)) | 0;
  }
  return STAGE_PALETTE[Math.abs(hash) % STAGE_PALETTE.length];
}

export function StageBadge({ stage }: { stage: string | null }) {
  if (!stage) return <span className="text-black">—</span>;
  return <Pill text={humanise(stage)} className={stageStyle(stage)} />;
}
