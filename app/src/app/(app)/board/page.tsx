import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { getCurrentUser, canViewAllWork, hasPermission } from '@/lib/auth/roles';
import { BoardView } from '@/components/BoardView';
import { buildBoardColumns } from '@/lib/workflow/board';
import type { WorkItemRow } from '@/types/work';

export const dynamic = 'force-dynamic';

// Same terminal statuses the Control Tower and filters.ts treat as "closed" —
// a board is about work still moving, not an archive of everything ever done.
const CLOSED = ['COMPLETED', 'CANCELLED', 'REJECTED'];

export default async function BoardPage() {
  const user = await getCurrentUser();
  // Matches the Control Tower's gate: an individual contributor's own queue is
  // a handful of items, which My Work already shows without needing a board.
  if (!canViewAllWork(user)) redirect('/my-work');

  const supabase = await createClient();

  const [workRes, myTasksRes] = await Promise.all([
    supabase.from('v_work_items').select('*')
      .not('status', 'in', `(${CLOSED.join(',')})`)
      .order('stage_deadline', { ascending: true, nullsFirst: false })
      .limit(300),
    // v_my_tasks is already scoped to the caller (see 0005_views.sql) — this
    // is only the set of work items the viewer currently holds an open task
    // for, used below to decide which cards they may drag.
    supabase.from('v_my_tasks').select('work_item_id'),
  ]);

  if (workRes.error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700">
        Could not load the board — {workRes.error.message}
      </div>
    );
  }

  const rows = (workRes.data ?? []) as WorkItemRow[];
  const heldIds = new Set(
    (myTasksRes.data ?? []).map((t) => t.work_item_id as string),
  );
  // STATUS_CONTROLLER (Vijaya, Nirmal) or ADMIN — may move any card, not only
  // ones they personally hold. See board.ts's canOverride note and migration
  // 0015/0021.
  const canOverride = hasPermission(user, 'change_status');
  const columns = buildBoardColumns(rows, heldIds, user?.id, canOverride);

  return (
    <div className="space-y-4">
      <div>
        <Link href="/control-tower" className="text-sm text-black hover:text-black">
          ← Control Tower
        </Link>
        <h1 className="mt-2 text-xl font-semibold text-black">Board</h1>
        <p className="mt-1 max-w-2xl text-sm text-black">
          {canOverride
            ? 'Drag any card into the next column to submit or approve it, or back a column to request changes. Work on hold isn’t draggable — open it to resume first.'
            : 'Drag a card you hold into the next column to submit or approve it, or back a column to request changes. Cards you don’t currently hold, and work on hold, aren’t draggable.'}
        </p>
      </div>

      {columns.length === 0 ? (
        <div className="rounded-lg border border-slate-200 bg-white p-10 text-center text-sm text-black">
          No active work to show.
        </div>
      ) : (
        <BoardView columns={columns} />
      )}
    </div>
  );
}
