import { humanise } from '@/lib/format';

/**
 * Status and priority pills.
 *
 * Colour is never the only signal — each pill carries its own text, so the
 * meaning survives greyscale printing and colour-blindness.
 */

const STATUS_STYLES: Record<string, string> = {
  NOT_STARTED:      'bg-slate-100 text-slate-700 ring-slate-200',
  IN_PROGRESS:      'bg-blue-50 text-blue-700 ring-blue-200',
  SUBMITTED:        'bg-indigo-50 text-indigo-700 ring-indigo-200',
  PENDING:          'bg-amber-50 text-amber-800 ring-amber-200',
  APPROVED:         'bg-emerald-50 text-emerald-700 ring-emerald-200',
  CHANGES_REQUIRED: 'bg-orange-50 text-orange-800 ring-orange-200',
  REJECTED:         'bg-red-50 text-red-700 ring-red-200',
  BLOCKED:          'bg-red-50 text-red-700 ring-red-200',
  ON_HOLD:          'bg-slate-100 text-slate-600 ring-slate-300',
  COMPLETED:        'bg-emerald-50 text-emerald-700 ring-emerald-200',
  CANCELLED:        'bg-slate-100 text-slate-500 ring-slate-200',
};

const PRIORITY_STYLES: Record<string, string> = {
  CRITICAL: 'bg-red-50 text-red-700 ring-red-200',
  HIGH:     'bg-orange-50 text-orange-800 ring-orange-200',
  MEDIUM:   'bg-slate-100 text-slate-700 ring-slate-200',
  LOW:      'bg-slate-50 text-slate-500 ring-slate-200',
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
  if (!status) return <span className="text-slate-400">—</span>;
  return <Pill text={humanise(status)} className={STATUS_STYLES[status] ?? STATUS_STYLES.NOT_STARTED} />;
}

export function PriorityBadge({ priority }: { priority: string | null }) {
  if (!priority) return <span className="text-slate-400">—</span>;
  return <Pill text={humanise(priority)} className={PRIORITY_STYLES[priority] ?? PRIORITY_STYLES.MEDIUM} />;
}

export function OverdueBadge({ days }: { days: number | null }) {
  if (days === null || days === undefined || days >= 0) return null;
  return <Pill text="Overdue" className="bg-red-50 text-red-700 ring-red-200" />;
}
