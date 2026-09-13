'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { addComment } from '@/lib/workflow/actions';

export function CommentForm({ workItemId }: { workItemId: string }) {
  const router = useRouter();
  const [body, setBody] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  return (
    <form
      className="mt-4"
      onSubmit={(e) => {
        e.preventDefault();
        startTransition(async () => {
          const r = await addComment(workItemId, body);
          if (r.ok) { setBody(''); setError(null); router.refresh(); }
          else setError(r.message);
        });
      }}
    >
      <label htmlFor="comment" className="sr-only">Add a comment</label>
      <textarea
        id="comment" rows={2} value={body} onChange={(e) => setBody(e.target.value)}
        placeholder="Add a comment…"
        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                   focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
      />
      {error && <p role="alert" className="mt-1 text-sm text-red-700">{error}</p>}
      <button
        type="submit" disabled={pending || !body.trim()}
        className="mt-2 rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white
                   hover:bg-slate-800 disabled:opacity-50">
        {pending ? 'Posting…' : 'Comment'}
      </button>
    </form>
  );
}
