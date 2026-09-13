'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { createWork } from '@/lib/workflow/actions';

/**
 * A one-field-fewer version of /work/new, reachable from every page rather
 * than only from the Control Tower. It deliberately skips who-does-what and
 * PO routing — those still need the full form — so this exists purely to
 * make "log this before I forget it" fast; anyone who needs the rest can
 * follow "Full form instead" without retyping the title.
 */
export function QuickAddWork() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [priority, setPriority] = useState('MEDIUM');
  const [deadline, setDeadline] = useState('');
  const [requestedBy, setRequestedBy] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function close() {
    setOpen(false);
    setTitle('');
    setPriority('MEDIUM');
    setDeadline('');
    setRequestedBy('');
    setError(null);
  }

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        className="rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800"
      >
        + Add work
      </button>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
            <h2 className="text-base font-semibold text-black">Quick add</h2>
            <p className="mt-1 text-sm text-black">
              Starts the workflow at its first stage, owned by you. Add a brief or assign people
              afterwards from the work item.
            </p>

            <form
              className="mt-4 space-y-3"
              onSubmit={(e) => {
                e.preventDefault();
                setError(null);
                start(async () => {
                  const r = await createWork({
                    title,
                    priority,
                    deadline: deadline || undefined,
                    requestedBy: requestedBy || undefined,
                    poRequired: false,
                  });
                  if (r.ok) {
                    close();
                    router.refresh();
                  } else {
                    setError(r.message);
                  }
                });
              }}
            >
              <div>
                <label htmlFor="qa-title" className="block text-sm font-medium text-black">
                  What is the work? <span className="text-red-600">*</span>
                </label>
                <input
                  id="qa-title" required autoFocus value={title}
                  onChange={(e) => setTitle(e.target.value)}
                  placeholder="Cardiac OPD poster"
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                             focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label htmlFor="qa-priority" className="block text-sm font-medium text-black">
                    Priority
                  </label>
                  <select
                    id="qa-priority" value={priority} onChange={(e) => setPriority(e.target.value)}
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                               focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
                  >
                    {['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'].map((p) => (
                      <option key={p} value={p}>{p[0] + p.slice(1).toLowerCase()}</option>
                    ))}
                  </select>
                </div>
                <div>
                  <label htmlFor="qa-deadline" className="block text-sm font-medium text-black">
                    Deadline
                  </label>
                  <input
                    id="qa-deadline" type="date" value={deadline}
                    onChange={(e) => setDeadline(e.target.value)}
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                               focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
                  />
                </div>
              </div>

              <div>
                <label htmlFor="qa-requested-by" className="block text-sm font-medium text-black">
                  Requested by
                </label>
                <input
                  id="qa-requested-by" value={requestedBy}
                  onChange={(e) => setRequestedBy(e.target.value)}
                  placeholder="Dr Tarang"
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                             focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
                />
              </div>

              {error && (
                <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>
              )}

              <div className="flex items-center justify-between gap-2 pt-1">
                <Link
                  href="/work/new" onClick={close}
                  className="text-sm text-black underline-offset-2 hover:underline"
                >
                  Full form instead →
                </Link>
                <div className="flex gap-2">
                  <button type="button" onClick={close} disabled={pending}
                    className="rounded-md border border-slate-300 px-3 py-2 text-sm text-black
                               hover:bg-slate-50 disabled:opacity-50">
                    Cancel
                  </button>
                  <button type="submit" disabled={pending || !title.trim()}
                    className="rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white
                               hover:bg-slate-800 disabled:opacity-50">
                    {pending ? 'Creating…' : 'Create'}
                  </button>
                </div>
              </div>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
