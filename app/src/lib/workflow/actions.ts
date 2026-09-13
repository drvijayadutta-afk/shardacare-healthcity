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
    case '42501': return message; // 'You do not hold this work item' / an admin-only override refused.
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

/* -------------------------------------------------------------------------- */
/* Admin overrides — adding, reassigning, and deleting tasks                 */
/* -------------------------------------------------------------------------- */

export async function addTaskToWorkItem(
  workItemId: string,
  assigneeId: string,
  note?: string,
): Promise<ActionResult> {
  if (!assigneeId) return { ok: false, message: 'Choose someone to give this task to.' };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('add_task_to_work_item', {
    p_work_item_id: workItemId,
    p_assignee_id: assigneeId,
    p_note: note?.trim() || null,
  });

  if (error) return { ok: false, message: describeError(error.code, error.message) };

  refresh(workItemId);
  const result = data as Record<string, unknown>;
  return {
    ok: true,
    message: `Task added for ${result.assignee_name}.`,
    detail: result,
  };
}

export async function reassignWorkItem(
  workItemId: string,
  newAssigneeId: string,
  note?: string,
): Promise<ActionResult> {
  if (!newAssigneeId) return { ok: false, message: 'Choose someone to reassign this to.' };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('reassign_work_item', {
    p_work_item_id: workItemId,
    p_new_assignee_id: newAssigneeId,
    p_note: note?.trim() || null,
  });

  if (error) return { ok: false, message: describeError(error.code, error.message) };

  refresh(workItemId);
  const result = data as Record<string, unknown>;
  return {
    ok: true,
    message: `Reassigned to ${result.new_assignee_name}.`,
    detail: result,
  };
}

export async function removeTask(
  taskId: string,
  reason?: string,
): Promise<ActionResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('remove_task', {
    p_task_id: taskId,
    p_reason: reason?.trim() || null,
  });

  if (error) return { ok: false, message: describeError(error.code, error.message) };

  const result = data as Record<string, unknown>;
  if (result.work_item_id) refresh(result.work_item_id as string);

  return {
    ok: true,
    message: result.cleared_assignment
      ? 'Task deleted. Nobody currently holds this work.'
      : 'Task deleted.',
    detail: result,
  };
}

/* -------------------------------------------------------------------------- */
/* Creating work                                                              */
/* -------------------------------------------------------------------------- */

export interface NewWorkInput {
  title: string;
  description?: string;
  category?: string;
  requestedBy?: string;
  priority: string;
  deadline?: string;
  poRequired: boolean;
  contentWriterId?: string;
  designerId?: string;
  releaserId?: string;
}

/**
 * Create a job, its first work item, and the first task.
 *
 * The people chosen here are what makes the rest automatic:
 * resolve_next_assignee looks for a work_item_owners row whose holder has the
 * stage's expected role, so naming the writer and designer up front is all the
 * routing needs. Every handoff after this one is the engine's.
 */
export async function createWork(input: NewWorkInput): Promise<ActionResult> {
  if (!input.title?.trim()) {
    return { ok: false, message: 'Give the work a name.' };
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false, message: 'Your session has expired. Sign in again.' };

  // Default workflow, first stage.
  const { data: wf, error: wfErr } = await supabase
    .from('workflow_templates')
    .select('id, workflow_stages(id, name, stage_order)')
    .eq('is_default', true)
    .maybeSingle();

  if (wfErr) return { ok: false, message: wfErr.message };
  if (!wf) {
    return {
      ok: false,
      message: 'No default workflow is configured. Run the schema migrations — 0012 defines it.',
    };
  }

  type Stage = { id: string; name: string; stage_order: number };
  const stages = ((wf.workflow_stages ?? []) as unknown as Stage[])
    .sort((a, b) => a.stage_order - b.stage_order);
  const first = stages[0];
  if (!first) return { ok: false, message: 'The default workflow has no stages.' };

  const { data: job, error: jobErr } = await supabase
    .from('jobs')
    .insert({
      name: input.title.trim(),
      description: input.description?.trim() || null,
      category: input.category?.trim() || null,
      created_by: user.id,
      requester_id: user.id,
    })
    .select('id')
    .single();

  if (jobErr) return { ok: false, message: jobErr.message };

  const { data: work, error: workErr } = await supabase
    .from('work_items')
    .insert({
      job_id: job.id,
      workflow_id: wf.id,
      current_stage_id: first.id,
      name: input.title.trim(),
      // Who asked for it, recorded as text: leadership and doctors do not have
      // accounts, and creating one for them would be inventing a user.
      description: input.requestedBy?.trim()
        ? `Requested by ${input.requestedBy.trim()}${input.description?.trim() ? `\n\n${input.description.trim()}` : ''}`
        : input.description?.trim() || null,
      status: 'IN_PROGRESS',
      priority: input.priority,
      deadline: input.deadline || null,
      po_required: input.poRequired,
      po_status: input.poRequired ? 'NOT_STARTED' : 'NOT_REQUIRED',
      owner_id: user.id,
      current_assignee_id: user.id,
      pending_with_id: user.id,
      created_by: user.id,
      requester_id: user.id,
    })
    .select('id')
    .single();

  if (workErr) return { ok: false, message: workErr.message };

  // The people the engine will route to. Duplicates are dropped: one person
  // may hold more than one of these roles.
  const owners = [
    { id: user.id, role: 'PRIMARY' },
    ...[input.contentWriterId, input.designerId, input.releaserId]
      .filter((id): id is string => !!id && id !== user.id)
      .map((id) => ({ id, role: 'COLLABORATOR' })),
  ];
  const seen = new Set<string>();
  const rows = owners
    .filter((o) => !seen.has(o.id) && seen.add(o.id))
    .map((o) => ({ work_item_id: work.id, user_id: o.id, owner_role: o.role }));

  const { error: ownerErr } = await supabase.from('work_item_owners').insert(rows);
  if (ownerErr) return { ok: false, message: ownerErr.message };

  const { error: taskErr } = await supabase.from('tasks').insert({
    work_item_id: work.id,
    stage_id: first.id,
    assignee_id: user.id,
    assigned_by: user.id,
    title: `${input.title.trim()} — ${first.name.replace(/_/g, ' ').toLowerCase()}`,
    action_type: 'COMPLETE_STAGE',
    priority: input.priority,
    due_date: input.deadline || null,
  });
  if (taskErr) return { ok: false, message: taskErr.message };

  await supabase.from('activity_log').insert({
    work_item_id: work.id,
    actor_id: user.id,
    action: 'CREATED',
    to_value: first.name,
  });

  revalidatePath('/my-work');
  revalidatePath('/control-tower');
  revalidatePath('/work');

  return {
    ok: true,
    message: 'Created.',
    detail: { workItemId: work.id, stage: first.name },
  };
}
