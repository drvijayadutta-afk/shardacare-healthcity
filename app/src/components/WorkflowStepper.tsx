import { humanise } from '@/lib/format';

interface Stage {
  id: string;
  name: string;
  stage_order: number;
  requires_approval: boolean;
}

/**
 * Workflow progress.
 *
 * Position is judged by stage_order rather than by array index, because the
 * PO stages are skipped entirely when po_required is false — an index-based
 * stepper would mark those as "done" when they never happened.
 */
export function WorkflowStepper({
  stages, currentOrder, poRequired,
}: {
  stages: Stage[];
  currentOrder: number | null;
  poRequired: boolean;
}) {
  // Hide the procurement detour on work that does not need it.
  const PO_STAGES = ['PO_REQUEST', 'PROCUREMENT_REVIEW', 'PO_APPROVAL', 'PO_RELEASED'];
  const visible = poRequired ? stages : stages.filter((s) => !PO_STAGES.includes(s.name));

  return (
    <ol className="flex flex-wrap gap-x-1 gap-y-2">
      {visible.map((s) => {
        const done    = currentOrder !== null && s.stage_order < currentOrder;
        const current = currentOrder !== null && s.stage_order === currentOrder;

        const style = current
          ? 'bg-slate-900 text-white ring-slate-900'
          : done
            ? 'bg-emerald-50 text-emerald-700 ring-emerald-200'
            : 'bg-white text-black ring-slate-200';

        return (
          <li key={s.id}
              aria-current={current ? 'step' : undefined}
              className={`inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs
                          font-medium ring-1 ring-inset ${style}`}>
            {done && <span aria-hidden>✓</span>}
            {humanise(s.name)}
            {s.requires_approval && !done && (
              <span className="opacity-60" title="Approval gate" aria-label="approval gate">⚑</span>
            )}
          </li>
        );
      })}
    </ol>
  );
}
