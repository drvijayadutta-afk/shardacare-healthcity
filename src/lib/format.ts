/** Shared display helpers. Kept in one place so "—" means the same everywhere. */

/** An absent value is shown as an em dash, never as a zero or a guess. */
export const DASH = '—';

export function formatDate(d: string | null | undefined): string {
  if (!d) return DASH;
  return new Date(d + 'T00:00:00').toLocaleDateString('en-GB', {
    day: 'numeric', month: 'short', year: 'numeric',
  });
}

/**
 * Days remaining, as text.
 *
 * null means no deadline is set — which is common in the imported data and
 * must read as "not set", not as "0 days" or "overdue".
 */
export function formatDaysRemaining(days: number | null | undefined): string {
  if (days === null || days === undefined) return DASH;
  if (days === 0) return 'Today';
  if (days === 1) return '1 day';
  if (days > 1) return `${days} days`;
  const late = Math.abs(days);
  return late === 1 ? '1 day late' : `${late} days late`;
}

export function humanise(token: string | null | undefined): string {
  if (!token) return DASH;
  return token.replace(/_/g, ' ').toLowerCase().replace(/^./, (c) => c.toUpperCase());
}

/** What the person holding this task actually has to do. */
const ACTION_LABELS: Record<string, string> = {
  COMPLETE_STAGE: 'Complete and submit',
  APPROVE: 'Approve or request changes',
  REVIEW: 'Review',
  REVISE: 'Revise and resubmit',
  RAISE_PO: 'Raise purchase order',
  APPROVE_PO: 'Approve purchase order',
  RELEASE_PO: 'Release PO to vendor',
  PRODUCE: 'Produce',
  PUBLISH: 'Publish',
  PROVIDE_INFO: 'Provide information',
};

export function actionLabel(actionType: string | null | undefined): string {
  if (!actionType) return DASH;
  return ACTION_LABELS[actionType] ?? humanise(actionType);
}
