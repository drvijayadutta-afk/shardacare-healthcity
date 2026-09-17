'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { addTaskToWorkItem, reassignWorkItem, removeTask, type ActionResult } from '@/lib/workflow/actions';

export interface AdminPerson { id: string; full_name: string }

type Dialog = 'add' | 'reassign' | 'delete' | null;

/**
 * An override panel for whoever controls the to-do list — STATUS_CONTROLLER
 * (Nirmal, Vijaya) plus ADMIN, per 0026 — separate from the normal Actions
 * section: everything above is "what the current holder can do with their
 * own work," this is "what a controller can do to someone else's." Kept
 * visually distinct so the two are never confused for the same kind of action.
 */
export function AdminControls({
  workItemId, people, currentTaskId, currentAssigneeName, canDelete,
}: {
  workItemId: string;
  people: AdminPerson[];
  /** The open task at the current stage, if one exists — null on an unassigned item. */
  currentTaskId: string | null;
  currentAssigneeName: string | null;
  /** Same STATUS_CONTROLLER/ADMIN check as adding/reassigning (0026) — passed
   *  separately only because the parent computes it once and shares it. */
  canDelete: boolean;
}) {
  const router = useRouter();
  const [dialog, setDialog] = useState<Dialog>(null);
  const [personId, setPersonId] = useState('');
  const [note, setNote] = useState('');
  const [result, setResult] = useState<ActionResult | null>(null);
  const [pending, startTransition] = useTransition();

  function close() {
    setDialog(null);
    setPersonId('');
    setNote('');
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

  return (
    <div>
      <p className="mb-3 text-xs text-black">
        Overrides the normal handoff. Visible to admins and workflow managers only.
      </p>
      <div className="flex flex-wrap gap-2">
        <button
          onClick={() => setDialog('add')} disabled={pending}
          className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm
                     font-medium text-black hover:bg-slate-50 disabled:opacity-50">
          Add task
        </button>
        <button
          onClick={() => setDialog('reassign')} disabled={pending}
          className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm
                     font-medium text-black hover:bg-slate-50 disabled:opacity-50">
          Reassign
        </button>
        {currentTaskId && canDelete && (
          <button
            onClick={() => setDialog('delete')} disabled={pending}
            className="rounded-md border border-red-200 bg-white px-3 py-2 text-sm
                       font-medium text-red-700 hover:bg-red-50 disabled:opacity-50">
            Delete current task
          </button>
        )}
      </div>

      {result && !dialog && (
        <p role="status"
           className={`mt-3 rounded-md px-3 py-2 text-sm ${
             result.ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-700'}`}>
          {result.message}
        </p>
      )}

      {dialog && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
            <h2 className="text-base font-semibold text-black">
              {dialog === 'add' && 'Add a task'}
              {dialog === 'reassign' && 'Reassign this work'}
              {dialog === 'delete' && 'Delete the current task'}
            </h2>
            <p className="mt-1 text-sm text-black">
              {dialog === 'add' &&
                `Gives someone a task on this stage without touching${
                  currentAssigneeName ? ` ${currentAssigneeName}'s` : ''
                } own task — use this for a helper or a second pair of eyes. ${
                  currentAssigneeName ? '' : 'Nobody currently holds this stage, so this also becomes the official handoff.'
                }`}
              {dialog === 'reassign' &&
                `Moves the current stage to someone else${
                  currentAssigneeName ? `, off ${currentAssigneeName}` : ''
                }. They get a task exactly as if the workflow had handed it to them.`}
              {dialog === 'delete' &&
                `Removes ${currentAssigneeName ?? "the current holder's"} open task outright, ` +
                  'rather than submitting or requesting changes. Use this to correct a mistake — ' +
                  'a duplicate task, or the wrong person — not as a way to skip a stage. ' +
                  'The work item becomes unassigned unless someone else still holds a task on it.'}
            </p>

            {(dialog === 'add' || dialog === 'reassign') && (
              <div className="mt-4">
                <label htmlFor="admin-person" className="block text-sm font-medium text-black">
                  {dialog === 'add' ? 'Give the task to' : 'Reassign to'}{' '}
                  <span className="text-red-600">*</span>
                </label>
                <select
                  id="admin-person" value={personId} onChange={(e) => setPersonId(e.target.value)}
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                             focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy">
                  <option value="">— choose —</option>
                  {people.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}
                </select>
              </div>
            )}

            <div className="mt-4">
              <label htmlFor="admin-note" className="block text-sm font-medium text-black">
                {dialog === 'delete' ? 'Reason' : 'Note'}
                <span className="font-normal text-black"> (optional)</span>
              </label>
              <textarea
                id="admin-note" rows={2} value={note} onChange={(e) => setNote(e.target.value)}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                           focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
              />
            </div>

            {result && !result.ok && (
              <p role="alert" className="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
                {result.message}
              </p>
            )}

            <div className="mt-5 flex justify-end gap-2">
              <button onClick={close} disabled={pending}
                className="rounded-md border border-slate-300 px-3 py-2 text-sm text-black
                           hover:bg-slate-50 disabled:opacity-50">
                Cancel
              </button>
              <button
                disabled={pending || ((dialog === 'add' || dialog === 'reassign') && !personId)}
                onClick={() => {
                  if (dialog === 'add') run(() => addTaskToWorkItem(workItemId, personId, note));
                  else if (dialog === 'reassign') run(() => reassignWorkItem(workItemId, personId, note));
                  else if (currentTaskId) run(() => removeTask(currentTaskId, note));
                }}
                className={`rounded-md px-3 py-2 text-sm font-medium text-white disabled:opacity-50 ${
                  dialog === 'delete' ? 'bg-red-600 hover:bg-red-700' : 'bg-brand-navy hover:bg-brand-navy-dark'}`}>
                {pending ? 'Working…'
                  : dialog === 'add' ? 'Add task'
                  : dialog === 'delete' ? 'Delete task' : 'Reassign'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
