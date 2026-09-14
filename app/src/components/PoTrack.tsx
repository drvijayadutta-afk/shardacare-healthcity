'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { advancePo, openPoTrack, updatePoDetails, type PoStatus } from '@/lib/workflow/collab';

export interface PoStep {
  step_order: number;
  code: string;
  label: string;
  state: 'done' | 'current' | 'pending' | 'rejected';
}

export interface PoDetails {
  id: string;
  po_number: string | null;
  vendor_name: string | null;
  amount: number | null;
  currency: string;
  description: string | null;
  status: string;
}

/**
 * The procurement track, drawn beside the main workflow rather than inside it.
 *
 * Procurement used to be four stages of the critical path, so an item waiting
 * on a PO showed "Procurement Review" as its status and looked stalled. It now
 * runs at the same time as production, which is only legible if it is drawn as
 * its own rail with its own state — hence this panel, and hence the line that
 * says plainly what is still holding up release.
 */

const STATE_STYLE: Record<PoStep['state'], { dot: string; text: string }> = {
  done:     { dot: 'bg-emerald-500 ring-emerald-100',  text: 'text-black' },
  current:  { dot: 'bg-amber-500 ring-amber-100',      text: 'text-black font-medium' },
  pending:  { dot: 'bg-slate-200 ring-slate-100',      text: 'text-black' },
  rejected: { dot: 'bg-red-500 ring-red-100',          text: 'text-red-700' },
};

const NEXT_STATUS: Record<string, { to: PoStatus; label: string } | undefined> = {
  NOT_STARTED: { to: 'REQUESTED', label: 'Raise PO' },
  REQUESTED:   { to: 'IN_REVIEW', label: 'Send to procurement review' },
  IN_REVIEW:   { to: 'APPROVED',  label: 'Approve PO' },
  APPROVED:    { to: 'RELEASED',  label: 'Issue to vendor' },
};

function money(amount: number | null, currency: string): string {
  if (amount === null || amount === undefined) return 'Not costed yet';
  return new Intl.NumberFormat('en-IN', {
    style: 'currency', currency: currency || 'INR', maximumFractionDigits: 0,
  }).format(amount);
}

export function PoTrack({
  workItemId, poRequired, poStatus, steps, po, canChangeStatus, blocksRelease,
}: {
  workItemId: string;
  poRequired: boolean;
  poStatus: string;
  steps: PoStep[];
  po: PoDetails | null;
  canChangeStatus: boolean;
  blocksRelease: boolean;
}) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [vendor, setVendor] = useState(po?.vendor_name ?? '');
  const [amount, setAmount] = useState(po?.amount != null ? String(po.amount) : '');
  const [pending, startTransition] = useTransition();

  // poRequired is a NOT NULL boolean and cannot represent "nobody has said" —
  // po_status can, and does, for the imported items whose source never
  // mentions a purchase order at all. Claiming "not needed" there would be
  // exactly as invented a fact as the default this app already had to fix
  // once (see 0014_po_not_assessed.sql). "Not required" is only true when
  // po_status actually confirms it.
  if (poStatus === 'NOT_ASSESSED') {
    return (
      <p className="mt-3 text-sm text-amber-700">
        Not assessed — the source did not say whether a purchase order is needed.
      </p>
    );
  }

  if (!poRequired) {
    return (
      <p className="mt-3 text-sm text-black">
        No purchase order needed for this work.
      </p>
    );
  }

  const next = NEXT_STATUS[poStatus];
  const isRejected = poStatus === 'REJECTED';
  const isReleased = poStatus === 'RELEASED';

  function run(fn: () => Promise<{ ok: boolean; message: string }>) {
    setError(null);
    startTransition(async () => {
      const r = await fn();
      if (!r.ok) setError(r.message);
      else router.refresh();
    });
  }

  return (
    <div className="mt-3">
      <div className="rounded-lg bg-slate-50 p-4">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <p className="text-xs font-medium uppercase tracking-wide text-black">
            Runs in parallel with the main workflow
          </p>
          {po?.po_number && (
            <span className="font-mono text-xs text-black">{po.po_number}</span>
          )}
        </div>

        <ol className="mt-3 space-y-2.5">
          {steps.map((s) => {
            const style = STATE_STYLE[isRejected ? 'rejected' : s.state];
            return (
              <li key={s.code} className="flex items-center gap-2.5 text-sm">
                <span className={`h-2.5 w-2.5 shrink-0 rounded-full ring-4 ${style.dot}`} />
                <span className={style.text}>{s.label}</span>
                {s.state === 'current' && !isRejected && (
                  <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs text-amber-800">
                    in progress
                  </span>
                )}
              </li>
            );
          })}
        </ol>

        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 border-t border-slate-200 pt-3 text-sm">
          <div>
            <dt className="text-xs text-black">Vendor</dt>
            <dd className="text-black">{po?.vendor_name ?? 'Not set'}</dd>
          </div>
          <div>
            <dt className="text-xs text-black">Value</dt>
            <dd className="text-black">{money(po?.amount ?? null, po?.currency ?? 'INR')}</dd>
          </div>
        </dl>

        {blocksRelease && !isReleased && (
          <p className="mt-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900">
            Production and approvals can continue. Release is held until this PO is issued.
          </p>
        )}
        {isReleased && (
          <p className="mt-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs text-emerald-900">
            PO issued — procurement is no longer holding this work.
          </p>
        )}
        {isRejected && (
          <p className="mt-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-900">
            This purchase order was rejected. Raise a new one before release.
          </p>
        )}

        {canChangeStatus && (
          <div className="mt-3 flex flex-wrap gap-2">
            {!po && (
              <button
                type="button" disabled={pending}
                onClick={() => run(() => openPoTrack(workItemId, amount ? Number(amount) : null))}
                className="rounded-md bg-slate-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-slate-800 disabled:opacity-50"
              >
                Raise purchase order
              </button>
            )}
            {po && next && !isRejected && (
              <button
                type="button" disabled={pending}
                onClick={() => run(() => advancePo(workItemId, next.to))}
                className="rounded-md bg-slate-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-slate-800 disabled:opacity-50"
              >
                {next.label}
              </button>
            )}
            {po && !isReleased && !isRejected && (
              <button
                type="button" disabled={pending}
                onClick={() => run(() => advancePo(workItemId, 'REJECTED'))}
                className="rounded-md px-3 py-1.5 text-xs font-medium text-red-700 ring-1 ring-inset ring-red-200 hover:bg-red-50 disabled:opacity-50"
              >
                Reject
              </button>
            )}
            {po && (
              <button
                type="button" disabled={pending}
                onClick={() => setEditing((v) => !v)}
                className="rounded-md px-3 py-1.5 text-xs font-medium text-black ring-1 ring-inset ring-slate-300 hover:bg-white disabled:opacity-50"
              >
                {editing ? 'Cancel' : 'Vendor & value'}
              </button>
            )}
          </div>
        )}

        {editing && po && (
          <form
            className="mt-3 grid gap-2 sm:grid-cols-[1fr_10rem_auto]"
            onSubmit={(e) => {
              e.preventDefault();
              run(async () => {
                const r = await updatePoDetails(workItemId, po.id, {
                  vendorName: vendor,
                  amount: amount ? Number(amount) : null,
                });
                if (r.ok) setEditing(false);
                return r;
              });
            }}
          >
            <input
              value={vendor} onChange={(e) => setVendor(e.target.value)}
              placeholder="Vendor name" aria-label="Vendor name"
              className="rounded-md border border-slate-300 px-2.5 py-1.5 text-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
            />
            <input
              value={amount} onChange={(e) => setAmount(e.target.value)}
              inputMode="decimal" placeholder="Amount (INR)" aria-label="Amount in rupees"
              className="rounded-md border border-slate-300 px-2.5 py-1.5 text-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
            />
            <button
              type="submit" disabled={pending}
              className="rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
            >
              Save
            </button>
          </form>
        )}

        {!canChangeStatus && (
          <p className="mt-3 text-xs text-black">
            Only Vijaya and Nirmal can move a purchase order along.
          </p>
        )}

        {error && <p role="alert" className="mt-2 text-sm text-red-700">{error}</p>}
      </div>
    </div>
  );
}
