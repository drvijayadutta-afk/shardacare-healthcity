'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import {
  submitForNextStage, requestChanges, putOnHold, resumeWork, approveWorkItem,
  type ActionResult,
} from '@/lib/workflow/actions';

interface Props {
  workItemId: string;
  canSubmit: boolean;
  canApprove: boolean;
  canHold: boolean;
  isOnHold: boolean;
}

type Dialog = 'submit' | 'changes' | 'hold' | 'approve' | null;

const BLOCKER_TYPES = [
  ['approval', 'Waiting on an approval'],
  ['vendor', 'Waiting on a vendor'],
  ['budget', 'Waiting on budget or costing'],
  ['info_needed', 'Waiting on information'],
  ['external', 'Waiting on something external'],
  ['dependency', 'Blocked by other work'],
  ['other', 'Something else'],
] as const;

export function WorkActions({ workItemId, canSubmit, canApprove, canHold, isOnHold }: Props) {
  const router = useRouter();
  const [dialog, setDialog] = useState<Dialog>(null);
  const [text, setText] = useState('');
  const [blocker, setBlocker] = useState('other');
  const [result, setResult] = useState<ActionResult | null>(null);
  const [pending, startTransition] = useTransition();

  function run(fn: () => Promise<ActionResult>) {
    startTransition(async () => {
      const r = await fn();
      setResult(r);
      if (r.ok) {
        setDialog(null);
        setText('');
        router.refresh();
      }
    });
  }

  const close = () => { setDialog(null); setText(''); setResult(null); };

  // Nothing to offer. Say why rather than rendering an empty bar, so a user
  // who expected a button understands the work simply is not with them.
  if (!canSubmit && !canApprove && !canHold) {
    return (
      <p className="rounded-md bg-slate-50 px-3 py-2 text-sm text-slate-500">
        This work is not with you right now, so there is nothing to action.
      </p>
    );
  }

  return (
    <div>
      <div className="flex flex-wrap gap-2">
        {canApprove && (
          <>
            <button
              onClick={() => setDialog('approve')} disabled={pending}
              className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white
                         hover:bg-emerald-700 disabled:opacity-50">
              Approve
            </button>
            <button
              onClick={() => setDialog('changes')} disabled={pending}
              className="rounded-md bg-orange-600 px-3 py-2 text-sm font-medium text-white
                         hover:bg-orange-700 disabled:opacity-50">
              Request Changes
            </button>
          </>
        )}

        {canSubmit && !canApprove && (
          <button
            onClick={() => setDialog('submit')} disabled={pending}
            className="rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white
                       hover:bg-slate-800 disabled:opacity-50">
            Submit for Next Stage
          </button>
        )}

        {canHold && (isOnHold ? (
          <button
            onClick={() => run(() => resumeWork(workItemId))} disabled={pending}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm
                       font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
            Resume
          </button>
        ) : (
          <button
            onClick={() => setDialog('hold')} disabled={pending}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm
                       font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
            Put On Hold
          </button>
        ))}
      </div>

      {result && (
        <p role="status"
           className={`mt-3 rounded-md px-3 py-2 text-sm ${
             result.ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-700'}`}>
          {result.message}
        </p>
      )}

      {dialog && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
            <h2 className="text-base font-semibold text-slate-900">
              {dialog === 'submit'   && 'Submit for next stage'}
              {dialog === 'approve'  && 'Approve this work'}
              {dialog === 'changes'  && 'Request changes'}
              {dialog === 'hold'     && 'Put on hold'}
            </h2>
            <p className="mt-1 text-sm text-slate-500">
              {dialog === 'submit'  && 'This hands the work to whoever the workflow assigns next.'}
              {dialog === 'approve' && 'This moves the work forward to the next stage.'}
              {dialog === 'changes' && 'This sends the work back to whoever submitted it last.'}
              {dialog === 'hold'    && 'The work stays at this stage until someone resumes it.'}
            </p>

            {dialog === 'hold' && (
              <div className="mt-4">
                <label htmlFor="blocker" className="block text-sm font-medium text-slate-700">
                  What is it waiting on?
                </label>
                <select
                  id="blocker" value={blocker} onChange={(e) => setBlocker(e.target.value)}
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm">
                  {BLOCKER_TYPES.map(([v, label]) => <option key={v} value={v}>{label}</option>)}
                </select>
              </div>
            )}

            <div className="mt-4">
              <label htmlFor="note" className="block text-sm font-medium text-slate-700">
                {dialog === 'changes' || dialog === 'hold' ? 'Reason' : 'Notes'}
                {(dialog === 'changes' || dialog === 'hold')
                  ? <span className="text-red-600"> *</span>
                  : <span className="font-normal text-slate-400"> (optional)</span>}
              </label>
              <textarea
                id="note" rows={3} value={text} onChange={(e) => setText(e.target.value)}
                placeholder={dialog === 'changes'
                  ? 'What needs to change?'
                  : dialog === 'hold' ? 'What is blocking this?' : ''}
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
              <button onClick={close} disabled={pending}
                className="rounded-md border border-slate-300 px-3 py-2 text-sm text-slate-700
                           hover:bg-slate-50 disabled:opacity-50">
                Cancel
              </button>
              <button
                disabled={pending || ((dialog === 'changes' || dialog === 'hold') && !text.trim())}
                onClick={() => {
                  if (dialog === 'submit')  run(() => submitForNextStage(workItemId, text));
                  if (dialog === 'approve') run(() => approveWorkItem(workItemId, text));
                  if (dialog === 'changes') run(() => requestChanges(workItemId, text));
                  if (dialog === 'hold')    run(() => putOnHold(workItemId, text, blocker));
                }}
                className="rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white
                           hover:bg-slate-800 disabled:opacity-50">
                {pending ? 'Working…' : 'Confirm'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
