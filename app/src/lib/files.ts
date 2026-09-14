/**
 * Attachment rules, shared by the upload widget and the server action.
 *
 * The real enforcement is the Supabase bucket's own `file_size_limit` and
 * `allowed_mime_types` (migration 0013) — a client check can always be
 * skipped. These exist so someone who picks a 60 MB video finds out before
 * waiting for the upload to fail, not after.
 */

/** Keep in step with file_size_limit in migration 0013. */
export const MAX_FILE_BYTES = 25 * 1024 * 1024;

export const BUCKET = 'work-files';

export const ACCEPTED_MIME = [
  'application/pdf',
  'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml', 'image/heic',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain', 'text/csv',
  'application/zip', 'application/x-zip-compressed',
  'video/mp4', 'video/quicktime',
] as const;

/** For the file picker's `accept` attribute. */
export const ACCEPT_ATTR = ACCEPTED_MIME.join(',');

export function isAcceptedType(mime: string): boolean {
  return (ACCEPTED_MIME as readonly string[]).includes(mime);
}

export function formatBytes(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined) return '—';
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${Math.round(kb)} KB`;
  const mb = kb / 1024;
  return `${mb.toFixed(mb < 10 ? 1 : 0)} MB`;
}

/**
 * A coarse kind, used to decide whether a thumbnail is worth showing and which
 * glyph to draw. Deliberately not a long extension table — the categories the
 * UI actually branches on are these five.
 */
export type FileKind = 'image' | 'pdf' | 'doc' | 'sheet' | 'slide' | 'other';

export function fileKind(mime: string | null | undefined, name = ''): FileKind {
  const m = (mime ?? '').toLowerCase();
  const ext = name.toLowerCase().split('.').pop() ?? '';

  if (m.startsWith('image/')) return 'image';
  if (m === 'application/pdf' || ext === 'pdf') return 'pdf';
  if (m.includes('word') || ['doc', 'docx'].includes(ext)) return 'doc';
  if (m.includes('sheet') || m.includes('excel') || ['xls', 'xlsx', 'csv'].includes(ext)) return 'sheet';
  if (m.includes('presentation') || m.includes('powerpoint') || ['ppt', 'pptx'].includes(ext)) return 'slide';
  return 'other';
}

/** Images and PDFs can be shown in place; everything else is a download. */
export function isPreviewable(mime: string | null | undefined, name = ''): boolean {
  const k = fileKind(mime, name);
  return k === 'image' || k === 'pdf';
}

/**
 * Strip anything that would make a storage key ambiguous or unsafe, while
 * keeping the name recognisable to a human reading the list.
 *
 * The stored key is prefixed with a UUID, so collisions are impossible and
 * this only has to be *legible* — it does not have to be unique.
 */
export function safeStorageName(name: string): string {
  const cleaned = name
    .normalize('NFKD')
    .replace(/[^\w.\- ]+/g, '')
    .replace(/\s+/g, '-')
    .replace(/-{2,}/g, '-')
    .replace(/^[.-]+/, '')
    .slice(-120);
  return cleaned || 'file';
}

/** `<work item id>/<uuid>-<legible name>` — see the storage policies in 0013. */
export function storageKey(workItemId: string, fileName: string): string {
  return `${workItemId}/${crypto.randomUUID()}-${safeStorageName(fileName)}`;
}
