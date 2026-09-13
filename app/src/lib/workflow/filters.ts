
/**
 * The filters behind the Control Tower tiles.
 *
 * Each predicate here MUST match the equivalent count in
 * get_control_tower_metrics() (migration 0009). They are kept side by side so
 * the mismatch is obvious if one is edited: a tile showing 16 that opens 14
 * rows destroys trust in every other number on the page.
 */

const OPEN = ['COMPLETED', 'CANCELLED', 'REJECTED'];

export const FILTERS = {
  active:            'Active work',
  due_today:         'Due today',
  due_this_week:     'Due this week',
  overdue:           'Overdue',
  awaiting_approval: 'Awaiting approval',
  po_pending:        'PO pending',
  blocked:           'Blocked or on hold',
  completed:         'Completed',
  needs_review:      'Needs review',
  unassigned:        'Unassigned',
  critical:          'Critical priority',
  all:               'All work',
} as const;

export type FilterKey = keyof typeof FILTERS;

export function isFilterKey(v: string | undefined): v is FilterKey {
  return !!v && v in FILTERS;
}

/**
 * The chips shown by default on the Work list. Everything else in FILTERS
 * still works (it's a real query param either way) but sits behind "More
 * filters" — twelve equal-weight pills in one row made every filter look
 * equally important, when in practice these seven cover what a manager
 * reaches for on an ordinary day.
 */
export const PRIMARY_FILTERS: readonly FilterKey[] = [
  'active', 'overdue', 'due_today', 'due_this_week',
  'awaiting_approval', 'po_pending', 'blocked',
];

function isoDaysFromNow(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

/**
 * Narrow to one person. Matches either the current assignee or the owner,
 * because on imported work nobody is assigned yet and the owner is the only
 * link to a person — filtering on assignee alone would return nothing for
 * exactly the rows a manager most wants to look at.
 */
/* eslint-disable @typescript-eslint/no-explicit-any */
export function applyOwnerFilter(query: any, ownerId: string) {
  return query.or(`current_assignee_id.eq.${ownerId},owner_id.eq.${ownerId}`);
}

export function applyFilter(query: any, filter: FilterKey) {
  const today = new Date().toISOString().slice(0, 10);

  switch (filter) {
    case 'active':
      return query.not('status', 'in', `(${OPEN.join(',')})`);
    case 'due_today':
      // Mirrors COALESCE(stage_deadline, deadline) = CURRENT_DATE. PostgREST
      // has no COALESCE in filters, so the view exposes both and we match the
      // same logic with an OR.
      return query.not('status', 'in', `(${OPEN.join(',')})`)
        .or(`stage_deadline.eq.${today},and(stage_deadline.is.null,deadline.eq.${today})`);
    case 'due_this_week':
      return query.not('status', 'in', `(${OPEN.join(',')})`)
        .or(
          `and(stage_deadline.gte.${today},stage_deadline.lte.${isoDaysFromNow(7)}),` +
          `and(stage_deadline.is.null,deadline.gte.${today},deadline.lte.${isoDaysFromNow(7)})`,
        );
    case 'overdue':
      return query.eq('is_overdue', true);
    case 'awaiting_approval':
      return query.eq('approval_required', true).eq('approval_status', 'PENDING')
        .not('status', 'in', `(${OPEN.join(',')})`);
    case 'po_pending':
      return query.eq('po_required', true)
        .not('po_status', 'in', '(RELEASED,NOT_REQUIRED)')
        .not('status', 'in', `(${OPEN.join(',')})`);
    case 'blocked':
      return query.in('status', ['BLOCKED', 'ON_HOLD']);
    case 'completed':
      return query.eq('status', 'COMPLETED');
    case 'needs_review':
      return query.eq('needs_review', true);
    case 'unassigned':
      return query.is('current_assignee_id', null)
        .not('status', 'in', `(${OPEN.join(',')})`);
    case 'critical':
      return query.eq('priority', 'CRITICAL')
        .not('status', 'in', `(${OPEN.join(',')})`);
    case 'all':
    default:
      return query;
  }
}
