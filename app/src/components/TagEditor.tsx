'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { addTag, removeTag, suggestTags } from '@/lib/workflow/collab';

export interface WorkTag {
  tag_id: string;
  slug: string;
  label: string;
  colour: string;
}

/**
 * Free-form tags with autocomplete.
 *
 * Free-form was the explicit choice, so the defence against "Hoarding",
 * "hoardings" and "HOARDING" becoming three tags is not an admin — it is the
 * suggestion list, plus the normalised unique key in the database. Showing
 * what already exists as someone types is what actually prevents the mess.
 */

const TINT: Record<string, string> = {
  slate:   'bg-slate-100 text-black ring-slate-200',
  blue:    'bg-blue-50 text-blue-700 ring-blue-200',
  green:   'bg-emerald-50 text-emerald-700 ring-emerald-200',
  amber:   'bg-amber-50 text-amber-800 ring-amber-200',
  red:     'bg-red-50 text-red-700 ring-red-200',
  violet:  'bg-violet-50 text-violet-700 ring-violet-200',
};

export function tagTint(colour: string | null | undefined): string {
  return TINT[colour ?? 'slate'] ?? TINT.slate;
}

export function TagEditor({
  workItemId, tags, canEdit,
}: {
  workItemId: string;
  tags: WorkTag[];
  canEdit: boolean;
}) {
  const router = useRouter();
  const [value, setValue] = useState('');
  const [options, setOptions] = useState<{ id: string; label: string }[]>([]);
  const [showOptions, setShowOptions] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const boxRef = useRef<HTMLDivElement>(null);

  // Debounced so a fast typist does not fire a query per keystroke.
  useEffect(() => {
    if (!canEdit) return;
    const t = setTimeout(() => {
      startTransition(async () => setOptions(await suggestTags(value)));
    }, 180);
    return () => clearTimeout(t);
  }, [value, canEdit]);

  useEffect(() => {
    function onAway(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setShowOptions(false);
    }
    document.addEventListener('mousedown', onAway);
    return () => document.removeEventListener('mousedown', onAway);
  }, []);

  const existing = new Set(tags.map((t) => t.label.toLowerCase()));
  const filtered = options.filter((o) => !existing.has(o.label.toLowerCase()));

  function commit(label: string) {
    const text = label.trim();
    if (!text) return;
    setValue('');
    setShowOptions(false);
    setError(null);
    startTransition(async () => {
      const r = await addTag(workItemId, text);
      if (!r.ok) setError(r.message);
      else router.refresh();
    });
  }

  function drop(tagId: string) {
    setError(null);
    startTransition(async () => {
      const r = await removeTag(workItemId, tagId);
      if (!r.ok) setError(r.message);
      else router.refresh();
    });
  }

  return (
    <div className="mt-3">
      <div className="flex flex-wrap items-center gap-1.5">
        {tags.map((t) => (
          <span
            key={t.tag_id}
            className={`inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium ring-1 ring-inset ${tagTint(t.colour)}`}
          >
            <Link href={`/work?tag=${encodeURIComponent(t.slug)}`} className="hover:underline">
              {t.label}
            </Link>
            {canEdit && (
              <button
                type="button"
                onClick={() => drop(t.tag_id)}
                disabled={pending}
                aria-label={`Remove tag ${t.label}`}
                className="-mr-0.5 rounded-full px-0.5 leading-none opacity-50 hover:opacity-100 disabled:opacity-30"
              >
                ×
              </button>
            )}
          </span>
        ))}

        {!tags.length && !canEdit && (
          <span className="text-sm text-black">No tags.</span>
        )}

        {canEdit && (
          <div ref={boxRef} className="relative">
            <input
              value={value}
              onChange={(e) => { setValue(e.target.value); setShowOptions(true); }}
              onFocus={() => setShowOptions(true)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') { e.preventDefault(); commit(value); }
                if (e.key === 'Escape') setShowOptions(false);
                if (e.key === 'Backspace' && !value && tags.length) drop(tags[tags.length - 1].tag_id);
              }}
              placeholder={tags.length ? 'Add tag…' : 'Add a tag…'}
              aria-label="Add a tag"
              maxLength={40}
              className="w-32 rounded-full border border-dashed border-slate-300 px-2.5 py-1 text-xs
                         focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
            />

            {showOptions && filtered.length > 0 && (
              <ul className="absolute left-0 top-full z-20 mt-1 min-w-40 overflow-hidden rounded-md border border-slate-200 bg-white py-1 shadow-lg">
                {filtered.map((o) => (
                  <li key={o.id}>
                    <button
                      type="button"
                      onClick={() => commit(o.label)}
                      className="block w-full px-3 py-1.5 text-left text-xs text-black hover:bg-slate-50"
                    >
                      {o.label}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </div>

      {error && <p role="alert" className="mt-2 text-sm text-red-700">{error}</p>}
    </div>
  );
}
