'use server';

import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';

export interface ActionResult {
  ok: boolean;
  message: string;
  detail?: Record<string, unknown>;
}

/**
 * Thin wrappers over the plpgsql handoff functions.
 *
 * The mutation logic deliberately is NOT here. One handoff writes to six
 * tables and must be all-or-nothing; the Supabase client cannot open a
 * transaction across statements, so the whole thing is one database function
 * and this layer only calls it and refreshes the affected pages.
 *
 * The functions run as SECURITY INVOKER, so the caller's RLS applies — a user
 * cannot act on work they cannot see, regardless of what the UI renders.
 */

/**
 * Postgres error codes the handoff functions raise deliberately. Anything else
 * is unexpected and its message is passed through rather than dressed up as a
 * friendly string, because a surprising failure should look surprising.
 */
function describeError(code: string | undefined, message: string): string {
  switch (code) {
    case '28000': return 'Your session has expired. Sign in again.';
    case '42501': return 'This work is not assigned to you.';
    case 'P0002': return 'That work item no longer exists.';
    case '22023': return message; // Raised with a specific, already-readable reason.
    default:      return message || 'Something went wrong.';
  }
}

function refresh(workItemId: string) {
  revalidatePath(`/work/${workItemId}`);
  revalidatePath('/my-work');
  revalidatePath('/control-tower');
}

export async function submitForNextStage(
  workItemId: string,
  notes?: string,
): Promise<ActionResult> {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc('submit_for_next_stage', {
    p_work_item_id: workItemId,
    p_notes: notes?.trim() || null,
  });

  if (error) {
    return { ok: false, message: describeError(error.code, error.message) };
  }

  refresh(workItemId);

  const result = data as Record<string, unknown>;

  // Not every successful submit advances the stage: parallel work waits for
  // the other collaborators, and sequential work passes to the next person at
  // the same stage. Saying "moved to X" in those cases would be a lie.
  if (result.advanced === false) {
    if (result.reason === 'awaiting_collaborators') {
      const n = result.pending_collaborators;
      return {
        ok: true,
        message: `Your part is submitted. Waiting on ${n} other ${n === 1 ? 'person' : 'people'} before this moves on.`,
        detail: result,
      };
    }
    if (result.reason === 'sequential_handoff') {
      return { ok: true, message: 'Submitted and passed to the next person in the sequence.', detail: result };
    }
  }

  if (result.completed === true) {
    return { ok: true, message: 'Submitted. This work is now complete.', detail: result };
  }

  return {
    ok: true,
    message: `Submitted. Now at ${String(result.to_stage ?? 'the next stage').replace(/_/g, ' ').toLowerCase()}.`,
    detail: result,
  };
}

export async function requestChanges(
  workItemId: string,
  reason: string,
): Promise<ActionResult> {
  if (!reason?.trim()) {
    return { ok: false, message: 'Give a reason so the person knows what to change.' };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('request_changes', {
    p_work_item_id: workItemId,
    p_reason: reason.trim(),
  });

  if (error) return { ok: false, message: describeError(error.code, error.message) };

  refresh(workItemId);
  const result = data as Record<string, unknown>;
  return {
    ok: true,
    message: `Sent back to ${String(result.returned_to_stage ?? 'the previous stage').replace(/_/g, ' ').toLowerCase()}.`,
    detail: result,
  };
}

export async function putOnHold(
  workItemId: string,
  reason: string,
  blockerType = 'other',
): Promise<ActionResult> {
  if (!reason?.trim()) {
    return { ok: false, message: 'Give a reason so others know what this is waiting on.' };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('put_on_hold', {
    p_work_item_id: workItemId,
    p_reason: reason.trim(),
    p_blocker_type: blockerType,
  });

  if (error) return { ok: false, message: describeError(error.code, error.message) };

  refresh(workItemId);
  return { ok: true, message: 'Put on hold. It stays at this stage until resumed.' };
}

export async function resumeWork(workItemId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc('resume_work', { p_work_item_id: workItemId });

  if (error) return { ok: false, message: describeError(error.code, error.message) };

  refresh(workItemId);
  return { ok: true, message: 'Resumed.' };
}

export async function approveWorkItem(
  workItemId: string,
  notes?: string,
): Promise<ActionResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('approve_work_item', {
    p_work_item_id: workItemId,
    p_notes: notes?.trim() || null,
  });

  if (error) return { ok: false, message: describeError(error.code, error.message) };

  refresh(workItemId);
  const result = data as Record<string, unknown>;

  if (result.completed === true) {
    return { ok: true, message: 'Approved. This work is now complete.', detail: result };
  }
  return {
    ok: true,
    message: `Approved. Now at ${String(result.to_stage ?? 'the next stage').replace(/_/g, ' ').toLowerCase()}.`,
    detail: result,
  };
}

export async function addComment(
  workItemId: string,
  body: string,
): Promise<ActionResult> {
  if (!body?.trim()) return { ok: false, message: 'Write something first.' };

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false, message: 'Your session has expired. Sign in again.' };

  const { error } = await supabase.from('comments').insert({
    work_item_id: workItemId,
    author_id: user.id,
    body: body.trim(),
    comment_type: 'COMMENT',
  });

  if (error) return { ok: false, message: error.message };

  revalidatePath(`/work/${workItemId}`);
  return { ok: true, message: 'Comment added.' };
}
