'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { getFileUrl, removeFile } from '@/lib/workflow/collab';
import { fileKind, formatBytes, isPreviewable, type FileKind } from '@/lib/files';
import { DASH } from '@/lib/format';

export interface AttachedFile {
  id: string;
  file_name: string;
  mime_type: string | null;
  size_bytes: number | null;
  uploaded_at: string;
  uploader: string | null;
  is_mine: boolean;
}

/**
 * The attachment list, with preview, download and removal.
 *
 * URLs are minted on demand rather than server-rendered with the page. A
 * signed URL embedded in HTML starts expiring the moment the page is cached,
 * and would put a working link to every file into the markup of a page that
 * may simply be sitting open on someone's second monitor.
 */

const GLYPH: Record<FileKind, string> = {
  image: '▣', pdf: '▤', doc: '▤', sheet: '▦', slide: '▥', other: '▢',
};

const KIND_TINT: Record<FileKind, string> = {
  image: 'bg-violet-50 text-violet-700',
  pdf:   'bg-red-50 text-red-700',
  doc:   'bg-blue-50 text-blue-700',
  sheet: 'bg-emerald-50 text-emerald-700',
  slide: 'bg-amber-50 text-amber-700',
  other: 'bg-slate-100 text-black',
};

export function FileList({
  workItemId, files, canRemoveAny,
}: {
  workItemId: string;
  files: AttachedFile[];
  canRemoveAny: boolean;
}) {
  const router = useRouter();
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<{ url: string; file: AttachedFile } | null>(null);
  const [, startTransition] = useTransition();

  function open(file: AttachedFile, mode: 'view' | 'download') {
    setBusyId(file.id);
    setError(null);
    startTransition(async () => {
      const r = await getFileUrl(file.id, { download: mode === 'download' });
      setBusyId(null);
      if (!r.ok) { setError(r.message); return; }

      if (mode === 'view' && isPreviewable(file.mime_type, file.file_name)) {
        setPreview({ url: r.url, file });
      } else {
        window.open(r.url, '_blank', 'noopener,noreferrer');
      }
    });
  }

  function remove(file: AttachedFile) {
    if (!confirm(`Remove "${file.file_name}"? This cannot be undone.`)) return;
    setBusyId(file.id);
    setError(null);
    startTransition(async () => {
      const r = await removeFile(workItemId, file.id);
      setBusyId(null);
      if (!r.ok) setError(r.message);
      else router.refresh();
    });
  }

  if (!files.length) {
    return <p className="mt-3 text-sm text-black">No files attached yet.</p>;
  }

  return (
    <>
      {error && <p role="alert" className="mt-3 text-sm text-red-700">{error}</p>}

      <ul className="mt-3 divide-y divide-slate-100">
        {files.map((f) => {
          const kind = fileKind(f.mime_type, f.file_name);
          const busy = busyId === f.id;
          return (
            <li key={f.id} className="flex items-center gap-3 py-2.5">
              <span
                aria-hidden
                className={`flex h-8 w-8 shrink-0 items-center justify-center rounded text-sm ${KIND_TINT[kind]}`}
              >
                {GLYPH[kind]}
              </span>

              <div className="min-w-0 flex-1">
                <button
                  type="button"
                  onClick={() => open(f, 'view')}
                  disabled={busy}
                  className="block max-w-full truncate text-left text-sm font-medium text-black hover:underline disabled:opacity-50"
                  title={f.file_name}
                >
                  {f.file_name}
                </button>
                <p className="text-xs text-black">
                  {formatBytes(f.size_bytes)} · {f.uploader ?? DASH} ·{' '}
                  {new Date(f.uploaded_at).toLocaleDateString('en-GB', {
                    day: 'numeric', month: 'short',
                  })}
                </p>
              </div>

              <div className="flex shrink-0 items-center gap-1">
                <button
                  type="button"
                  onClick={() => open(f, 'download')}
                  disabled={busy}
                  className="rounded px-2 py-1 text-xs font-medium text-black hover:bg-slate-100 disabled:opacity-50"
                >
                  {busy ? '…' : 'Download'}
                </button>
                {(f.is_mine || canRemoveAny) && (
                  <button
                    type="button"
                    onClick={() => remove(f)}
                    disabled={busy}
                    className="rounded px-2 py-1 text-xs font-medium text-black hover:bg-red-50 hover:text-red-700 disabled:opacity-50"
                  >
                    Remove
                  </button>
                )}
              </div>
            </li>
          );
        })}
      </ul>

      {preview && (
        <div
          role="dialog"
          aria-modal="true"
          aria-label={preview.file.file_name}
          onClick={() => setPreview(null)}
          className="fixed inset-0 z-50 flex flex-col bg-slate-900/80 p-4 sm:p-8"
        >
          <div className="mb-3 flex items-center gap-3 text-white">
            <p className="min-w-0 flex-1 truncate text-sm font-medium">
              {preview.file.file_name}
            </p>
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); window.open(preview.url, '_blank', 'noopener,noreferrer'); }}
              className="rounded bg-white/10 px-2.5 py-1 text-xs hover:bg-white/20"
            >
              Open in new tab
            </button>
            <button
              type="button"
              onClick={() => setPreview(null)}
              className="rounded bg-white/10 px-2.5 py-1 text-xs hover:bg-white/20"
            >
              Close
            </button>
          </div>

          <div
            onClick={(e) => e.stopPropagation()}
            className="flex min-h-0 flex-1 items-center justify-center overflow-auto rounded-lg bg-white"
          >
            {fileKind(preview.file.mime_type, preview.file.file_name) === 'image' ? (
              /* eslint-disable-next-line @next/next/no-img-element */
              <img
                src={preview.url}
                alt={preview.file.file_name}
                className="max-h-full max-w-full object-contain"
              />
            ) : (
              <iframe
                src={preview.url}
                title={preview.file.file_name}
                className="h-full w-full"
              />
            )}
          </div>
        </div>
      )}
    </>
  );
}
