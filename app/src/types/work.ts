/**
 * Shape of a v_work_items row.
 *
 * Hand-written rather than generated because the Supabase CLI cannot reach a
 * project from this environment. If the view in
 * app/supabase/migrations/0005_views.sql changes, change this too — nothing
 * enforces the correspondence at compile time.
 */
export interface WorkItemRow {
  id: string;
  name: string;
  description: string | null;
  deliverable_type: string | null;

  job_id: string | null;
  job_name: string | null;
  job_category: string | null;
  campaign_id: string | null;
  campaign_name: string | null;

  workflow_id: string | null;
  workflow_name: string | null;
  multi_owner_behavior: string | null;
  current_stage_id: string | null;
  stage_name: string | null;
  stage_order: number | null;
  stage_requires_approval: boolean | null;
  stage_is_terminal: boolean | null;

  status: string;
  substatus: string | null;
  priority: string;

  owner_id: string | null;
  owner_name: string | null;
  current_assignee_id: string | null;
  assignee_name: string | null;
  pending_with_id: string | null;
  pending_with: string | null;

  deadline: string | null;
  stage_deadline: string | null;
  days_remaining: number | null;
  is_overdue: boolean | null;

  approval_required: boolean;
  approval_status: string;
  po_required: boolean;
  po_status: string;
  po_request_id: string | null;
  estimated_amount: number | null;

  blocked_by_id: string | null;
  blocker_type: string | null;
  blocker_note: string | null;

  needs_review: boolean;
  review_notes: string | null;
  source_text: string | null;

  submission_count: number;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
}
