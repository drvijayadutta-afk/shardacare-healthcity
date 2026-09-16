'use client';

import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { recordUpload } from '@/lib/workflow/collab';
import {
  ACCEPT_ATTR, BUCKET, MAX_FILE_BYTES, formatBytes, isAcceptedType, storageKey,
} from '@/lib/files';

/**
 * Attach files to a work item.
 *
 * The bytes go from the browser straight into Supabase Storage, never through
 * a Server Action — action requests are capped at 1 MB, which a single phone
 * photo already exceeds. The upload runs under the user's own session, so the
 * storage policies in migration 0013 decide what is allowed; the Server Action
 * afterwards only writes the row that points at the object.
 *
 * Each file is tracked separately: on a batch where one fails, the rest still
 * land, and the failure names the file rather than the batch.
 */

type Progress = {
  name: string;
  size: number;
  state: 'uploading' | 'done' | 'error';
  message?: string;
};

export function FileUpload({ workItemId }: { workItemId: string }) {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);
  const [items, setItems] = useState<Progress[]>([]);
  const [pending, startTransition] = useTransition();

  async function uploadOne(file: File): Promise<Progress> {
    const base = { name: file.name, size: file.size };

    if (file.size > MAX_FILE_BYTES) {
      return {
        ...base, state: 'error',
        message: `Too large (${formatBytes(file.size)}). The limit is ${formatBytes(MAX_FILE_BYTES)}.`,
      };
    }
    if (file.type && !isAcceptedType(file.type)) {
      return { ...base, state: 'error', message: `${file.type} files are not accepted.` };
    }

    const supabase = createClient();
    const path = storageKey(workItemId, file.name);

    const { error } = await supabase.storage
      .from(BUCKET)
      .upload(path, file, { contentType: file.type || 'application/octet-stream' });

    if (error) {
      return { ...base, state: 'error', message: error.message };
    }

    const recorded = await recordUpload(workItemId, {
      storagePath: path,
      fileName: file.name,
      mimeType: file.type || 'application/octet-stream',
      sizeBytes: file.size,
    });

    return recorded.ok
      ? { ...base, state: 'done' }
      : { ...base, state: 'error', message: recorded.message };
  }

  function handleFiles(list: FileList | null) {
    const files = Array.from(list ?? []);
    if (!files.length) return;

    setItems(files.map((f) => ({ name: f.name, size: f.size, state: 'uploading' as const })));

    startTransition(async () => {
      // Sequential on purpose. Next dispatches Server Actions one at a time per
      // client anyway, so firing them together only queues them behind each
      // other while making the progress list lie about what is happening.
      const results: Progress[] = [];
      for (const f of files) {
        const r = await uploadOne(f);
        results.push(r);
        setItems([...results, ...files.slice(results.length).map((rest) => ({
          name: rest.name, size: rest.size, state: 'uploading' as const,
        }))]);
      }
      router.refresh();
      // Clear the successes after a beat; keep failures on screen to be read.
      setTimeout(() => setItems((cur) => cur.filter((i) => i.state === 'error')), 2500);
    });
  }

  return (
    <div className="mt-3">
      <div
        onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragging(false);
          handleFiles(e.dataTransfer.files);
        }}
        className={`rounded-lg border-2 border-dashed p-4 text-center transition-colors ${
          dragging ? 'border-brand-navy bg-slate-50' : 'border-slate-200'
        }`}
      >
        <p className="text-sm text-black">
          Drag files here, or{' '}
          <button
            type="button"
            onClick={() => inputRef.current?.click()}
            disabled={pending}
            className="font-medium text-black underline underline-offset-2 hover:text-black disabled:opacity-50"
          >
            browse
          </button>
        </p>
        <p className="mt-1 text-xs text-black">
          PDF, images, Office documents, video. Up to {formatBytes(MAX_FILE_BYTES)} each.
        </p>
        <input
          ref={inputRef}
          type="file"
          multiple
          accept={ACCEPT_ATTR}
          className="hidden"
          onChange={(e) => { handleFiles(e.target.files); e.target.value = ''; }}
        />
      </div>

      {items.length > 0 && (
        <ul className="mt-2 space-y-1">
          {items.map((i, n) => (
            <li
              key={`${i.name}-${n}`}
              className={`flex flex-wrap items-baseline gap-x-2 rounded-md px-2 py-1.5 text-xs ${
                i.state === 'error' ? 'bg-red-50 text-red-800' : 'bg-slate-50 text-black'
              }`}
            >
              <span className="font-medium">{i.name}</span>
              <span className="text-black">{formatBytes(i.size)}</span>
              <span className="ml-auto">
                {i.state === 'uploading' && 'Uploading…'}
                {i.state === 'done' && 'Attached'}
                {i.state === 'error' && i.message}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
