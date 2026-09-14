'use server';

import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { BUCKET } from '@/lib/files';
import type { ActionResult } from './actions';

/**
 * Attachments, tags, comment threads and the parallel PO track.
 *
 * Kept apart from actions.ts, which wraps the handoff engine. These are
 * ordinary row writes: RLS decides what is allowed, so each one is a single
 * statement and there is no transaction to protect.
 *
 * The file BYTES never pass through here. A Server Action request is capped at
 * 1 MB, so the browser uploads straight to Supabase Storage under the caller's
 * own session (the storage policies in 0013 enforce access), and this layer
 * only records the row that points at it.
 */

function fail(message: string): ActionResult {
  return { ok: false, message };
}

function refresh(workItemId: string) {
  revalidatePath(`/work/${workItemId}`);
  revalidatePath('/work');
  revalidatePath('/my-work');
  revalidatePath('/control-tower');
}

/** Postgres codes the migrations raise on purpose. */
function describe(code: string | undefined, message: string): string {
  switch (code) {
    case '28000': return 'Your session has expired. Sign in again.';
    case '42501': return message || 'You do not have permission to do that.';
    case 'P0002': return 'That work item no longer exists.';
    case '22023': return message;
    case '23505': return 'That already exists.';
    default:      return message || 'Something went wrong.';
  }
}

/* -------------------------------------------------------------------------- */
/* Attachments                                                                 */
/* -------------------------------------------------------------------------- */

export interface RecordedFile {
  storagePath: string;
  fileName: string;
  mimeType: string;
  sizeBytes: number;
}

/**
 * Record an upload that has already landed in the bucket.
 *
 * Called after the browser's `storage.upload()` resolves. If this fails the
 * object is orphaned in storage but invisible to the app — which is the right
 * way round: a row pointing at a missing object would render as a broken
 * download for everyone.
 */
export async function recordUpload(
  workItemId: string,
  file: RecordedFile,
): Promise<ActionResult> {
  if (!file.storagePath.startsWith(`${workItemId}/`)) {
    // The storage policy enforces this too. Refusing here as well keeps a
    // mismatched row from ever being written.
    return fail('That file does not belong to this work item.');
  }

  const supabase = await createClient();
  const { error } = await supabase.from('files').insert({
    work_item_id: workItemId,
    file_name: file.fileName,
    storage_path: file.storagePath,
    mime_type: file.mimeType,
    size_bytes: file.sizeBytes,
  });

  if (error) return fail(describe(error.code, error.message));

  await supabase.from('activity_log').insert({
    work_item_id: workItemId,
    action: 'FILE_ATTACHED',
    to_value: file.fileName,
  });

  refresh(workItemId);
  return { ok: true, message: `${file.fileName} attached.` };
}

/**
 * A short-lived signed URL for one file.
 *
 * The bucket is private, so this is the only way to read an object. Five
 * minutes is long enough to click through and short enough that a URL pasted
 * into a chat stops working.
 */
export async function getFileUrl(
  fileId: string,
  opts?: { download?: boolean },
): Promise<{ ok: true; url: string } | { ok: false; message: string }> {
  const supabase = await createClient();

  // Read the path through RLS rather than trusting one from the client.
  const { data: row, error } = await supabase
    .from('files')
    .select('storage_path, file_name')
    .eq('id', fileId)
    .is('deleted_at', null)
    .maybeSingle();

  if (error) return { ok: false, message: describe(error.code, error.message) };
  if (!row) return { ok: false, message: 'That file is no longer available.' };

  const { data, error: signErr } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(row.storage_path, 300,
      opts?.download ? { download: row.file_name } : undefined);

  if (signErr || !data) {
    return { ok: false, message: signErr?.message ?? 'Could not open that file.' };
  }
  return { ok: true, url: data.signedUrl };
}

/**
 * Soft delete: the row keeps its place in the audit trail and the object is
 * removed from the bucket, so the storage bill does not grow forever.
 */
export async function removeFile(
  workItemId: string,
  fileId: string,
): Promise<ActionResult> {
  const supabase = await createClient();

  const { data: row } = await supabase
    .from('files').select('storage_path, file_name')
    .eq('id', fileId).maybeSingle();

  const { error } = await supabase
    .from('files')
    .update({ deleted_at: new Date().toISOString() })
    .eq('id', fileId);

  if (error) return fail(describe(error.code, error.message));

  if (row?.storage_path) {
    // Best effort. If the object survives, the row is already hidden.
    await supabase.storage.from(BUCKET).remove([row.storage_path]);
  }

  await supabase.from('activity_log').insert({
    work_item_id: workItemId,
    action: 'FILE_REMOVED',
    to_value: row?.file_name ?? null,
  });

  refresh(workItemId);
  return { ok: true, message: 'File removed.' };
}

/* -------------------------------------------------------------------------- */
/* Tags                                                                        */
/* -------------------------------------------------------------------------- */

/**
 * Add a tag by the text someone typed, creating it if it is new.
 *
 * The find-or-create happens inside attach_tag() in the database, so two
 * people inventing the same tag at the same moment get one tag rather than a
 * unique violation.
 */
export async function addTag(workItemId: string, label: string): Promise<ActionResult> {
  const trimmed = label.trim();
  if (!trimmed) return fail('Type a tag first.');

  const supabase = await createClient();
  const { error } = await supabase.rpc('attach_tag', {
    p_work_item_id: workItemId,
    p_label: trimmed,
  });

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: `Tagged "${trimmed}".` };
}

export async function removeTag(workItemId: string, tagId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase
    .from('work_item_tags')
    .delete()
    .eq('work_item_id', workItemId)
    .eq('tag_id', tagId);

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: 'Tag removed.' };
}

/** Existing tags, for the autocomplete. Free-form still benefits from a nudge. */
export async function suggestTags(prefix: string): Promise<{ id: string; label: string }[]> {
  const supabase = await createClient();
  let q = supabase.from('tags').select('id, label').order('label').limit(8);
  if (prefix.trim()) q = q.ilike('slug', `${prefix.trim().toLowerCase()}%`);

  const { data } = await q;
  return data ?? [];
}

/* -------------------------------------------------------------------------- */
/* Comments                                                                    */
/* -------------------------------------------------------------------------- */

export async function replyToComment(
  workItemId: string,
  parentId: string,
  body: string,
): Promise<ActionResult> {
  const trimmed = body.trim();
  if (!trimmed) return fail('Write something first.');

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return fail('Your session has expired. Sign in again.');

  const { error } = await supabase.from('comments').insert({
    work_item_id: workItemId,
    parent_id: parentId,
    author_id: user.id,
    body: trimmed,
  });

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: 'Reply posted.' };
}

export async function editComment(
  workItemId: string,
  commentId: string,
  body: string,
): Promise<ActionResult> {
  const trimmed = body.trim();
  if (!trimmed) return fail('A comment cannot be empty.');

  const supabase = await createClient();
  const { error } = await supabase
    .from('comments').update({ body: trimmed }).eq('id', commentId);

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: 'Comment updated.' };
}

/** Soft delete, so a thread does not develop holes where replies hang loose. */
export async function deleteComment(
  workItemId: string,
  commentId: string,
): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase
    .from('comments')
    .update({ deleted_at: new Date().toISOString() })
    .eq('id', commentId);

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: 'Comment deleted.' };
}

export async function setCommentResolved(
  workItemId: string,
  commentId: string,
  resolved: boolean,
): Promise<ActionResult> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  const { error } = await supabase.from('comments').update({
    is_resolved: resolved,
    resolved_by: resolved ? user?.id ?? null : null,
    resolved_at: resolved ? new Date().toISOString() : null,
  }).eq('id', commentId);

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: resolved ? 'Marked resolved.' : 'Reopened.' };
}

/* -------------------------------------------------------------------------- */
/* PO track — runs in parallel with the main workflow                          */
/* -------------------------------------------------------------------------- */

export type PoStatus = 'REQUESTED' | 'IN_REVIEW' | 'APPROVED' | 'RELEASED' | 'REJECTED';

/** Open procurement early, before departmental approval opens it automatically. */
export async function openPoTrack(
  workItemId: string,
  amount?: number | null,
): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc('open_po_track', {
    p_work_item_id: workItemId,
    p_amount: amount ?? null,
    p_description: null,
  });

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: 'Purchase order raised.' };
}

export async function advancePo(
  workItemId: string,
  to: PoStatus,
  note?: string,
): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc('advance_po_track', {
    p_work_item_id: workItemId,
    p_to_status: to,
    p_note: note ?? null,
  });

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: `Purchase order moved to ${to.toLowerCase().replace('_', ' ')}.` };
}

/** Record the vendor and value against an open PO. */
export async function updatePoDetails(
  workItemId: string,
  poId: string,
  details: { vendorName?: string; amount?: number | null; description?: string },
): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.from('po_requests').update({
    vendor_name: details.vendorName?.trim() || null,
    amount: details.amount ?? null,
    description: details.description?.trim() || null,
  }).eq('id', poId);

  if (error) return fail(describe(error.code, error.message));

  refresh(workItemId);
  return { ok: true, message: 'Purchase order updated.' };
}
