'use client';

import { useState } from 'react';

/**
 * The 6pm message, with a one-tap copy.
 *
 * `navigator.clipboard` needs a secure context and can be refused, so the
 * textarea stays on screen and selectable rather than being hidden behind the
 * button. If the copy fails the text is still right there to select by hand —
 * which is the whole point of this page.
 */
export function CopyDigest({ text }: { text: string }) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle');

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setState('copied');
      setTimeout(() => setState('idle'), 2500);
    } catch {
      setState('failed');
    }
  }

  return (
    <div className="mt-3">
      <textarea
        readOnly
        value={text}
        rows={Math.min(20, text.split('\n').length + 1)}
        aria-label="End of day message"
        onFocus={(e) => e.currentTarget.select()}
        className="w-full resize-y rounded-md border border-slate-300 bg-slate-50 px-3 py-2
                   font-mono text-xs leading-relaxed text-black
                   focus:border-brand-navy focus:outline-none focus:ring-1 focus:ring-brand-navy"
      />
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <button
          type="button"
          onClick={copy}
          className="rounded-md bg-brand-navy px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-navy-dark"
        >
          Copy for WhatsApp
        </button>
        <a
          href={`https://wa.me/?text=${encodeURIComponent(text)}`}
          target="_blank"
          rel="noopener noreferrer"
          className="rounded-md px-3 py-1.5 text-sm font-medium text-black ring-1 ring-inset ring-slate-300 hover:bg-slate-50"
        >
          Open WhatsApp
        </a>
        {state === 'copied' && <span className="text-sm text-emerald-700">Copied.</span>}
        {state === 'failed' && (
          <span className="text-sm text-black">
            Copy was blocked — select the text above instead.
          </span>
        )}
      </div>
    </div>
  );
}
