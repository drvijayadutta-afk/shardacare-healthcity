'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import {
  deleteComment, editComment, replyToComment, setCommentResolved,
} from '@/lib/workflow/collab';
import { addComment } from '@/lib/workflow/actions';
import { humanise } from '@/lib/format';

export interface CommentRow {
  id: string;
  body: string;
  comment_type: string;
  created_at: string;
  parent_id: string | null;
  is_resolved: boolean;
  deleted_at: string | null;
  author: string | null;
  is_mine: boolean;
}

/**
 * Comments as threads rather than a flat log.
 *
 * parent_id and is_resolved have been in the schema since the first migration
 * and were never surfaced, so every clarification and every "done, fixed that"
 * landed as another top-level entry and the list became impossible to read on
 * a busy item. Replies nest one level only — deeper nesting turns into a
 * sideways staircase on a phone, and in practice a second level is where the
 * conversation actually happens.
 */

function when(iso: string): string {
  const d = new Date(iso);
  const mins = Math.round((Date.now() - d.getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  if (mins < 1440) return `${Math.round(mins / 60)}h ago`;
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
}

function Composer({
  placeholder, submitLabel, initial = '', autoFocus = false, onSubmit, onCancel,
}: {
  placeholder: string;
  submitLabel: string;
  initial?: string;
  autoFocus?: boolean;
  onSubmit: (body: string) => Promise<{ ok: boolean; message: string }>;
  onCancel?: () => void;
}) {
  const router = useRouter();
  const [body, setBody] = useState(initial);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  return (
    <form
      className="mt-2"
      onSubmit={(e) => {
        e.preventDefault();
        startTransition(async () => {
          const r = await onSubmit(body);
          if (r.ok) { setBody(''); setError(null); onCancel?.(); router.refresh(); }
          else setError(r.message);
        });
      }}
    >
      <textarea
        rows={2} value={body} autoFocus={autoFocus}
        onChange={(e) => setBody(e.target.value)}
        placeholder={placeholder}
        aria-label={placeholder}
        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm
                   focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
      />
      {error && <p role="alert" className="mt-1 text-sm text-red-700">{error}</p>}
      <div className="mt-1.5 flex gap-2">
        <button
          type="submit" disabled={pending || !body.trim()}
          className="rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
        >
          {pending ? 'Saving…' : submitLabel}
        </button>
        {onCancel && (
          <button
            type="button" onClick={onCancel}
            className="rounded-md px-3 py-1.5 text-sm font-medium text-black hover:bg-slate-100"
          >
            Cancel
          </button>
        )}
      </div>
    </form>
  );
}

function Comment({
  c, workItemId, replies, canModerate,
}: {
  c: CommentRow;
  workItemId: string;
  replies: CommentRow[];
  canModerate: boolean;
}) {
  const router = useRouter();
  const [mode, setMode] = useState<'view' | 'reply' | 'edit'>('view');
  const [error, setError] = useState<string | null>(null);
  const [, startTransition] = useTransition();

  function act(fn: () => Promise<{ ok: boolean; message: string }>) {
    setError(null);
    startTransition(async () => {
      const r = await fn();
      if (!r.ok) setError(r.message);
      else router.refresh();
    });
  }

  const deleted = !!c.deleted_at;

  return (
    <li className={c.is_resolved ? 'opacity-60' : undefined}>
      <div className="flex flex-wrap items-baseline gap-2">
        <span className="text-sm font-medium text-black">{c.author ?? 'Unknown'}</span>
        {c.comment_type !== 'COMMENT' && (
          <span className="rounded bg-orange-50 px-1.5 py-0.5 text-xs text-orange-800">
            {humanise(c.comment_type)}
          </span>
        )}
        {c.is_resolved && (
          <span className="rounded bg-emerald-50 px-1.5 py-0.5 text-xs text-emerald-800">
            Resolved
          </span>
        )}
        <span className="text-xs text-black">{when(c.created_at)}</span>
      </div>

      {mode === 'edit' && !deleted ? (
        <Composer
          placeholder="Edit your comment" submitLabel="Save" initial={c.body} autoFocus
          onSubmit={(body) => editComment(workItemId, c.id, body)}
          onCancel={() => setMode('view')}
        />
      ) : (
        <p className={`mt-0.5 whitespace-pre-wrap text-sm ${deleted ? 'italic text-black' : 'text-black'}`}>
          {deleted ? 'This comment was deleted.' : c.body}
        </p>
      )}

      {!deleted && mode === 'view' && (
        <div className="mt-1 flex flex-wrap gap-3 text-xs text-black">
          <button type="button" onClick={() => setMode('reply')} className="hover:text-black">
            Reply
          </button>
          <button
            type="button"
            onClick={() => act(() => setCommentResolved(workItemId, c.id, !c.is_resolved))}
            className="hover:text-black"
          >
            {c.is_resolved ? 'Reopen' : 'Resolve'}
          </button>
          {c.is_mine && (
            <button type="button" onClick={() => setMode('edit')} className="hover:text-black">
              Edit
            </button>
          )}
          {(c.is_mine || canModerate) && (
            <button
              type="button"
              onClick={() => act(() => deleteComment(workItemId, c.id))}
              className="hover:text-red-700"
            >
              Delete
            </button>
          )}
        </div>
      )}

      {error && <p role="alert" className="mt-1 text-xs text-red-700">{error}</p>}

      {mode === 'reply' && (
        <Composer
          placeholder="Write a reply…" submitLabel="Reply" autoFocus
          onSubmit={(body) => replyToComment(workItemId, c.id, body)}
          onCancel={() => setMode('view')}
        />
      )}

      {replies.length > 0 && (
        <ul className="mt-3 space-y-3 border-l-2 border-slate-100 pl-3">
          {replies.map((r) => (
            <Comment
              key={r.id} c={r} workItemId={workItemId} replies={[]} canModerate={canModerate}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

export function CommentThread({
  workItemId, comments, canModerate,
}: {
  workItemId: string;
  comments: CommentRow[];
  canModerate: boolean;
}) {
  const [showResolved, setShowResolved] = useState(false);

  const roots = comments.filter((c) => !c.parent_id);
  const repliesOf = (id: string) =>
    comments.filter((c) => c.parent_id === id)
      .sort((a, b) => a.created_at.localeCompare(b.created_at));

  // A deleted root with living replies must stay, or the replies vanish with it.
  const visible = roots.filter((c) => {
    if (c.deleted_at && repliesOf(c.id).length === 0) return false;
    if (c.is_resolved && !showResolved) return false;
    return true;
  });

  const resolvedCount = roots.filter((c) => c.is_resolved).length;

  return (
    <>
      {resolvedCount > 0 && (
        <button
          type="button"
          onClick={() => setShowResolved((v) => !v)}
          className="mt-2 text-xs text-black hover:text-black"
        >
          {showResolved ? 'Hide' : 'Show'} {resolvedCount} resolved
        </button>
      )}

      {visible.length > 0 ? (
        <ul className="mt-3 space-y-4">
          {visible.map((c) => (
            <Comment
              key={c.id} c={c} workItemId={workItemId}
              replies={repliesOf(c.id)} canModerate={canModerate}
            />
          ))}
        </ul>
      ) : (
        <p className="mt-3 text-sm text-black">
          {resolvedCount > 0 ? 'Nothing open.' : 'No comments yet.'}
        </p>
      )}

      <div className="mt-4 border-t border-slate-100 pt-3">
        <Composer
          placeholder="Add a comment…" submitLabel="Comment"
          onSubmit={(body) => addComment(workItemId, body)}
        />
      </div>
    </>
  );
}
