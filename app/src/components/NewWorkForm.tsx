'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { createWork } from '@/lib/workflow/actions';

export interface Person { id: string; full_name: string; roles: string[] }

function Select({ label, hint, value, onChange, people, role }: {
  label: string; hint: string; value: string;
  onChange: (v: string) => void; people: Person[]; role: string;
}) {
  const eligible = people.filter((p) => p.roles.includes(role));
  return (
    <div>
      <label className="block text-sm font-medium text-slate-700">{label}</label>
      <select
        value={value} onChange={(e) => onChange(e.target.value)}
        className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                   focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
      >
        <option value="">— not decided yet —</option>
        {eligible.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}
      </select>
      <p className="mt-1 text-xs text-slate-500">
        {eligible.length === 0
          ? `Nobody holds the ${role.replace(/_/g, ' ').toLowerCase()} role yet.`
          : hint}
      </p>
    </div>
  );
}

export function NewWorkForm({ people }: { people: Person[] }) {
  const router = useRouter();
  const [f, setF] = useState({
    title: '', description: '', category: '', requestedBy: '',
    priority: 'MEDIUM', deadline: '', poRequired: false,
    contentWriterId: '', designerId: '', releaserId: '',
  });
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const set = (k: keyof typeof f) => (v: string | boolean) => setF({ ...f, [k]: v });

  const field =
    'mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm ' +
    'focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900';

  return (
    <form
      className="space-y-5"
      onSubmit={(e) => {
        e.preventDefault();
        start(async () => {
          const r = await createWork(f);
          if (r.ok) router.push(`/work/${(r.detail as { workItemId: string }).workItemId}`);
          else setError(r.message);
        });
      }}
    >
      <div>
        <label className="block text-sm font-medium text-slate-700">
          What is the work? <span className="text-red-600">*</span>
        </label>
        <input required value={f.title} onChange={(e) => set('title')(e.target.value)}
          placeholder="Cardiac OPD poster" className={field} />
      </div>

      <div>
        <label className="block text-sm font-medium text-slate-700">
          Brief <span className="font-normal text-slate-400">(optional)</span>
        </label>
        <textarea rows={3} value={f.description} onChange={(e) => set('description')(e.target.value)}
          placeholder="What was agreed in the discussion" className={field} />
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label className="block text-sm font-medium text-slate-700">Requested by</label>
          <input value={f.requestedBy} onChange={(e) => set('requestedBy')(e.target.value)}
            placeholder="Dr Tarang" className={field} />
          <p className="mt-1 text-xs text-slate-500">
            Free text — doctors and leadership do not need accounts.
          </p>
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700">Category</label>
          <input value={f.category} onChange={(e) => set('category')(e.target.value)}
            placeholder="department" className={field} />
          <p className="mt-1 text-xs text-slate-500">
            Decides which approver the work routes to.
          </p>
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label className="block text-sm font-medium text-slate-700">Priority</label>
          <select value={f.priority} onChange={(e) => set('priority')(e.target.value)} className={field}>
            {['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'].map((p) =>
              <option key={p} value={p}>{p[0] + p.slice(1).toLowerCase()}</option>)}
          </select>
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700">
            Deadline <span className="font-normal text-slate-400">(optional)</span>
          </label>
          <input type="date" value={f.deadline} onChange={(e) => set('deadline')(e.target.value)}
            className={field} />
          <p className="mt-1 text-xs text-slate-500">Leave empty if there isn&rsquo;t one.</p>
        </div>
      </div>

      <label className="flex items-start gap-2 rounded-md bg-slate-50 px-3 py-2">
        <input type="checkbox" checked={f.poRequired} className="mt-0.5"
          onChange={(e) => set('poRequired')(e.target.checked)} />
        <span className="text-sm text-slate-700">
          <strong>A purchase order is needed</strong>
          <span className="mt-0.5 block text-xs text-slate-500">
            After Parul approves, this routes through PO request, procurement review,
            PO approval and release before production. Leave unticked and it goes
            straight to production.
          </span>
        </span>
      </label>

      <fieldset className="rounded-md border border-slate-200 p-4">
        <legend className="px-1 text-sm font-medium text-slate-900">Who does what</legend>
        <p className="mb-3 text-xs text-slate-500">
          The work moves to these people automatically as each stage is submitted.
          Anyone left undecided can be set later, but the handoff will pause there.
        </p>
        <div className="grid gap-4 sm:grid-cols-3">
          <Select label="Content" hint="Writes the copy, then reviews the finished piece."
            role="CONTENT_WRITER" people={people}
            value={f.contentWriterId} onChange={set('contentWriterId') as (v: string) => void} />
          <Select label="Design" hint="Produces the artwork, and the production stage."
            role="DESIGNER" people={people}
            value={f.designerId} onChange={set('designerId') as (v: string) => void} />
          <Select label="Release" hint="Takes it live once approved."
            role="SOCIAL_MEDIA" people={people}
            value={f.releaserId} onChange={set('releaserId') as (v: string) => void} />
        </div>
      </fieldset>

      {error && (
        <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>
      )}

      <div className="flex gap-2">
        <button type="submit" disabled={pending || !f.title.trim()}
          className="rounded-md bg-slate-900 px-4 py-2 text-sm font-medium text-white
                     hover:bg-slate-800 disabled:opacity-50">
          {pending ? 'Creating…' : 'Create work'}
        </button>
        <button type="button" onClick={() => router.back()} disabled={pending}
          className="rounded-md border border-slate-300 px-4 py-2 text-sm text-slate-700 hover:bg-slate-50">
          Cancel
        </button>
      </div>
    </form>
  );
}
