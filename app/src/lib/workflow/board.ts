import type { WorkItemRow } from '@/types/work';

export interface BoardCard {
  id: string;
  name: string;
  jobName: string | null;
  priority: string;
  status: string;
  ownerName: string | null;
  pendingWith: string | null;
  daysRemaining: number | null;
  isOverdue: boolean | null;
  stageOrder: number;
  stageName: string;
  requiresApproval: boolean;
  isOnHold: boolean;
  /** May this viewer pick the card up at all? */
  canDrag: boolean;
  /** Dragging it forward calls approve_work_item rather than submit_for_next_stage. */
  canApprove: boolean;
  canSubmit: boolean;
  /** True when canDrag is TRUE only because of the change_status override, not because the viewer holds the card. */
  isOverride: boolean;
}

export interface BoardColumn {
  /** current_stage_id (or a name fallback) scoped by workflow — see note below. */
  key: string;
  stageOrder: number;
  stageName: string;
  workflowName: string | null;
  cards: BoardCard[];
}

/**
 * Groups work into stage columns and works out, per card, whether the viewer
 * may drag it — mirroring the same holdsIt / canApprove / canSubmit rules the
 * Work Detail page uses for its action buttons (see work/[id]/page.tsx).
 *
 * This is presentation only, same as those buttons: a drag never does
 * anything a button on the detail page couldn't already do, it calls the same
 * submit_for_next_stage / approve_work_item / request_changes functions, and
 * RLS plus those functions' own checks remain the real boundary. Getting the
 * check here wrong only means offering a drag that the server would refuse,
 * not a security gap.
 *
 * canOverride mirrors public.can_change_status() (granted by the
 * STATUS_CONTROLLER role / ADMIN's change_status permission — see migration
 * 0015). Vijaya and Nirmal are meant to be able to move ANY card, not only
 * ones they personally hold ("move work that is neither theirs nor at their
 * gate" per 0015's own comment) — holdsIt alone was the whole gate here
 * before, which is why the board only ever let them drag their own one or two
 * cards. approve_work_item and request_changes already honour this override
 * via the enforce_status_change_permission trigger; submit_for_next_stage
 * needs the matching bypass added server-side (migration 0021) for the
 * forward, non-approval-gated case to actually succeed once dragged.
 *
 * On-hold work stays visible rather than disappearing from the board — a
 * board that quietly drops stuck work would make the team's blockers
 * invisible, which is the opposite of what a control tower is for — but it is
 * never draggable, even under the override: resuming it is a deliberate
 * action on the work item, not a side effect of a drag.
 *
 * Columns are keyed by (workflow_id, current_stage_id), not by stage_order
 * alone. Legacy rows sit on a separate three-stage "Imported (unclassified)"
 * template (see database/seed.sql) whose stages are numbered 1-3 — the same
 * numbers the real workflow's early stages use. Keying on the number alone
 * would silently merge two unrelated stages that happen to share it into one
 * column labelled with whichever name got there first, which is exactly the
 * kind of quiet misrepresentation this app otherwise goes out of its way to
 * avoid (see the Control Tower's own comments on that).
 */
export function buildBoardColumns(
  rows: WorkItemRow[],
  heldWorkItemIds: Set<string>,
  userId: string | undefined,
  canOverride = false,
): BoardColumn[] {
  const byStage = new Map<string, BoardColumn>();

  for (const w of rows) {
    // No current stage — nothing for a stage board to place it in.
    if (w.stage_order === null || !w.stage_name) continue;

    const isOnHold = w.status === 'ON_HOLD';
    const holdsIt =
      heldWorkItemIds.has(w.id) ||
      w.current_assignee_id === userId ||
      w.owner_id === userId;
    const mayAct = holdsIt || canOverride;

    const canApprove = mayAct && !isOnHold && !!w.stage_requires_approval;
    const canSubmit = mayAct && !isOnHold && !w.stage_requires_approval;

    const card: BoardCard = {
      id: w.id,
      name: w.name,
      jobName: w.job_name,
      priority: w.priority,
      status: w.status,
      ownerName: w.owner_name,
      pendingWith: w.pending_with,
      daysRemaining: w.days_remaining,
      isOverdue: w.is_overdue,
      stageOrder: w.stage_order,
      stageName: w.stage_name,
      requiresApproval: !!w.stage_requires_approval,
      isOnHold,
      canDrag: canApprove || canSubmit,
      canApprove,
      canSubmit,
      isOverride: !holdsIt && (canApprove || canSubmit),
    };

    const key = `${w.workflow_id ?? 'none'}::${w.current_stage_id ?? w.stage_name}`;
    let col = byStage.get(key);
    if (!col) {
      col = {
        key, stageOrder: w.stage_order, stageName: w.stage_name,
        workflowName: w.workflow_name, cards: [],
      };
      byStage.set(key, col);
    }
    col.cards.push(card);
  }

  // Grouped by workflow first so a legacy template's stages stay together
  // rather than interleaving with the standard flow's on matching numbers,
  // then by that workflow's own stage order.
  return [...byStage.values()].sort((a, b) =>
    (a.workflowName ?? '').localeCompare(b.workflowName ?? '') || a.stageOrder - b.stageOrder,
  );
}
