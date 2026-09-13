'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import {
  approveWorkItem, submitForNextStage, requestChanges, type ActionResult,
} from '@/lib/workflow/actions';
import { StatusBadge, PriorityBadge, StageBadge } from '@/components/Badges';
import { formatDaysRemaining, humanise } from '@/lib/format';
import type { BoardCard, BoardColumn } from '@/lib/workflow/board';

type Pending = { card: BoardCard; direction: 'forward' | 'backward' } | null;

/**
 * A drag never targets a specific stage the way the drop column suggests.
 * Dropping forward asks the engine to advance the card by whatever edge is
 * actually configured (which can differ under PO branching); dropping
 * backward asks it to send the card back to whoever holds it now. Either way
 * the card settles wherever the server puts it once the page refreshes — that
 * can be a different column than the one it was dropped on, which is called
 * out in the confirm dialog rather than silently corrected.
 */
export function BoardView({ columns }: { columns: BoardColumn[] }) {
  const router = useRouter();
  const [draggedCard, setDraggedCard] = useState<BoardCard | null>(null);
  const [draggedFromKey, setDraggedFromKey] = useState<string | null>(null);
  const [overStage, setOverStage] = useState<string | null>(null);
  const [pending, setPending] = useState<Pending>(null);
  const [notes, setNotes] = useState('');
  const [result, setResult] = useState<ActionResult | null>(null);
  const [busy, startTransition] = useTransition();

  function close() {
    setPending(null);
    setNotes('');
    setResult(null);
  }

  function run(fn: () => Promise<ActionResult>) {
    startTransition(async () => {
      const r = await fn();
      setResult(r);
      if (r.ok) {
        close();
        router.refresh();
      }
    });
  }

  function handleDrop(targetKey: string, targetStageOrder: number) {
    setOverStage(null);
    const card = draggedCard;
    const fromKey = draggedFromKey;
    setDraggedCard(null);
    setDraggedFromKey(null);
    if (!card || !card.canDrag) return;
    if (targetKey === fromKey) return; // same column — there is no saved order to change

    setResult(null);
    if (targetStageOrder > card.stageOrder) {
      setPending({ card, direction: 'forward' });
    } else if (card.canApprove) {
      setPending({ card, direction: 'backward' });
    } else {
      setResult({
        ok: false,
        message: `Only whoever approves "${humanise(card.stageName)}" can send this back a stage.`,
      });
    }
  }

  return (
    <div>
      {result && !pending && (
        <p role="status"
           className={`mb-3 rounded-md px-3 py-2 text-sm ${
             result.ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-700'}`}>
          {result.message}
        </p>
      )}

      <div className="-mx-4 flex gap-3 overflow-x-auto px-4 pb-2">
        {columns.map((col) => (
          <div
            key={col.key}
            onDragOver={(e) => {
              if (!draggedCard) return;
              e.preventDefault();
              setOverStage(col.key);
            }}
            onDragLeave={() => setOverStage((s) => (s === col.key ? null : s))}
            onDrop={(e) => { e.preventDefault(); handleDrop(col.key, col.stageOrder); }}
            className={`flex w-72 shrink-0 flex-col rounded-lg border p-2 transition ${
              overStage === col.key
                ? 'border-slate-900 bg-slate-100 ring-2 ring-slate-900/10'
                : 'border-slate-200 bg-slate-100/60'
            }`}
          >
            <div className="flex items-center justify-between px-1.5 py-1">
              <StageBadge stage={col.stageName} />
              <span className="text-xs font-medium text-black">{col.cards.length}</span>
            </div>

            <div className="flex flex-col gap-2">
              {col.cards.map((card) => (
                <div
                  key={card.id}
                  draggable={card.canDrag}
                  onDragStart={(e) => {
                    if (!card.canDrag) { e.preventDefault(); return; }
                    setDraggedCard(card);
                    setDraggedFromKey(col.key);
                    e.dataTransfer.effectAllowed = 'move';
                  }}
                  onDragEnd={() => { setDraggedCard(null); setDraggedFromKey(null); }}
                  title={
                    card.canDrag
                      ? card.canApprove
                        ? 'Drag into the next column to approve, or back a column to request changes'
                        : 'Drag into the next column to submit'
                      : card.isOnHold
                        ? 'On hold — open the work item to resume it before moving it'
                        : 'This work is not with you right now, so it cannot be dragged'
                  }
                  className={`rounded-md border bg-white p-2.5 text-sm shadow-sm transition ${
                    card.canDrag
                      ? 'cursor-grab border-slate-200 hover:border-slate-400 active:cursor-grabbing'
                      : 'cursor-default border-slate-200 opacity-70'
                  } ${draggedCard?.id === card.id ? 'opacity-40' : ''} ${
                    card.isOnHold ? 'border-dashed' : ''
                  }`}
                >
                  <Link href={`/work/${card.id}`}
                    className="font-medium text-black underline-offset-2 hover:underline">
                    {card.name}
                  </Link>
                  {card.jobName && card.jobName !== card.name && (
                    <div className="mt-0.5 truncate text-xs text-black">{card.jobName}</div>
                  )}
                  <div className="mt-2 flex flex-wrap items-center gap-1">
                    <StatusBadge status={card.status} />
                    <PriorityBadge priority={card.priority} />
                    {card.requiresApproval && (
                      <span className="opacity-60" title="Approval gate" aria-label="approval gate">⚑</span>
                    )}
                  </div>
                  <div className="mt-1.5 flex items-center justify-between gap-2 text-xs text-black">
                    <span className="truncate">{card.pendingWith ?? card.ownerName ?? '—'}</span>
                    <span className={card.isOverdue ? 'whitespace-nowrap font-medium text-red-700' : 'whitespace-nowrap'}>
                      {formatDaysRemaining(card.daysRemaining)}
                    </span>
                  </div>
                </div>
              ))}
              {col.cards.length === 0 && (
                <p className="px-1.5 py-3 text-center text-xs text-black">Empty</p>
              )}
            </div>
          </div>
        ))}
      </div>

      {pending && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
            <h2 className="text-base font-semibold text-black">
              {pending.direction === 'forward'
                ? (pending.card.canApprove ? 'Approve this work' : 'Submit for next stage')
                : 'Request changes'}
            </h2>
            <p className="mt-1 text-sm text-black">
              {pending.direction === 'forward'
                ? `Moves "${pending.card.name}" forward. The workflow decides the exact next ` +
                  'stage, which may not be the column you dropped it on.'
                : `Sends "${pending.card.name}" back to whoever submitted it last. Say what needs to change.`}
            </p>

            <div className="mt-4">
              <label htmlFor="board-note" className="block text-sm font-medium text-black">
                {pending.direction === 'backward' ? 'Reason' : 'Notes'}
                {pending.direction === 'backward'
                  ? <span className="text-red-600"> *</span>
                  : <span className="font-normal text-black"> (optional)</span>}
              </label>
              <textarea
                id="board-note" rows={3} value={notes} onChange={(e) => setNotes(e.target.value)}
                placeholder={pending.direction === 'backward' ? 'What needs to change?' : ''}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                           focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
              />
            </div>

            {result && !result.ok && (
              <p role="alert" className="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
                {result.message}
              </p>
            )}

            <div className="mt-5 flex justify-end gap-2">
              <button onClick={close} disabled={busy}
                className="rounded-md border border-slate-300 px-3 py-2 text-sm text-black
                           hover:bg-slate-50 disabled:opacity-50">
                Cancel
              </button>
              <button
                disabled={busy || (pending.direction === 'backward' && !notes.trim())}
                onClick={() => {
                  const { card, direction } = pending;
                  if (direction === 'backward') run(() => requestChanges(card.id, notes));
                  else if (card.canApprove) run(() => approveWorkItem(card.id, notes));
                  else run(() => submitForNextStage(card.id, notes));
                }}
                className="rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white
                           hover:bg-slate-800 disabled:opacity-50">
                {busy ? 'Working…' : 'Confirm'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
