# Supabase Schema — Relationships Explained

## Design Principle: Zero Hardcoding

Every name, department, approval chain, PO approver, and SLA lives in a **data row**, not in code or a CHECK constraint tied to a specific person. The only hardcoded values are **workflow-neutral vocabulary** (status enums like `IN_PROGRESS`, `APPROVED`) — never *who* does something.

---

## Entity Relationship Overview

```
auth.users (Supabase Auth)
    │ 1:1
    ▼
auth_users ──────────────┐
    │ M:M (via                │
    │ user_role_assignments)  │
    ▼                          │
user_roles                    │
                               │
departments ◄──────────────────┤ head_id
    │                          │
approval_authorities ──────────┤ approver_id (configurable, not hardcoded)
                               │
workflow_templates             │
    │ 1:M                      │
    ▼                          │
workflow_stages                │
    │ 1:M                      │
    ▼                          │
workflow_transitions           │
    │ (from_stage → to_stage)  │
    ▼                          │
stage_sla_config               │
                               │
jobs ──────────────────────────┤ requester_id, created_by_id
    │ 1:M                      │
    ▼                          │
work_items ─────────────────────┤ owner_id, current_assignee_id
    │ references workflow_id, current_stage_id
    │
    ├── 1:M → work_item_owners (multi-owner support)
    ├── 1:M → submissions
    ├── 1:M → files
    ├── 1:M → approvals
    ├── 1:M → comments
    ├── 1:M → activity_log
    ├── 1:M → notifications
    └── 0:1 → po_requests
```

---

## Table-by-Table Relationships

### 1. `auth_users` → Supabase `auth.users`
- **1:1 extension table.** Supabase's built-in `auth.users` handles credentials; `auth_users` stores app-specific profile data (name, avatar, active flag).
- `id` is both PK and FK to `auth.users.id` — this is the standard Supabase pattern so RLS can use `auth.uid()` directly against your own tables.

### 2. `user_roles` + `user_role_assignments` (Many-to-Many)
- A user can hold **multiple roles** (e.g., someone is both `CREATOR` and `APPROVER` for different work types).
- `permissions` is a JSONB array — **this is the configurability point**: adding a new permission doesn't require a schema change, just a data update.
- Nothing here hardcodes "Vijaya is an approver" — that's a *role assignment row*, editable by an Admin without touching code.

### 3. `departments`
- Standalone lookup table. `head_id` references `auth_users` — so "who heads this department" is data, changeable anytime.
- Work items don't reference `departments` directly in this schema (the current job list doesn't clearly map tasks to departments) — instead, `approval_authorities.work_category` does the routing. If you later want department-scoped work, add a `department_id` FK to `jobs`.

### 4. `approval_authorities` — **The Configurable Approval Chain**
This is the answer to "do not hardcode approval chains." Instead of a CHECK constraint or a switch statement saying "if branding, approver = Parul," you get a **data table**:

| approver_id | work_category | approval_level | budget_min | budget_max |
|---|---|---|---|---|
| (Parul's UUID) | branding | 1 | 0 | 999999999 |
| (Akshay's UUID) | print | 1 | 0 | 50000 |
| (CFO's UUID) | print | 2 | 50001 | 999999999 |

The workflow engine queries this table at runtime: "who approves `work_category = 'branding'` for this budget?" Change the approver by editing a row — no deploy needed.

### 5. `workflow_templates` → `workflow_stages` → `workflow_transitions` (1:M chains)
This is the workflow engine's backbone:

- **`workflow_templates`**: one row per workflow *shape* (e.g., "Standard Campaign," "Vendor Branding," "Simple Collateral"). `multi_owner_behavior` here answers the ambiguity from earlier analysis — it's set per template, not guessed at runtime.
- **`workflow_stages`**: ordered stages belonging to a template (`stage_order` enforces sequence). Each stage declares its own `sla_default_days`, `requires_approval`, `expected_owner_role` — again, data not code.
- **`workflow_transitions`**: explicit edges. `from_stage_id → to_stage_id` keyed by `trigger_condition` (`SUBMISSION`, `APPROVED`, `CHANGES_REQUIRED`, `REJECTED`, `PO_RELEASED`). This is what lets "Changes Required" route backward to a *different* stage than "Approved" routes forward — fully configurable per workflow template, satisfying your Return Rule and PO branching rule without any hardcoded if/else in application code.
- **`stage_sla_config`**: overrides `workflow_stages.sla_default_days` per priority level (`CRITICAL` gets fewer days than `LOW`). Optional table — falls back to the stage default if no row exists.

### 6. `jobs` → `work_items` (1:M)
- A `job` is the parent container (e.g., "Mother & Child Camp Campaign"). `work_items` are the individual deliverables/tasks under it (newspaper ad, WhatsApp, emailer...).
- This directly mirrors the "Campaign with Multiple Deliverables" pattern found in your job list — each deliverable becomes its own `work_item` row with its own stage/owner/deadline, while `job_id` groups them for campaign-level reporting.

### 7. `work_items` — the Hub Table
Everything else hangs off `work_items.id`. Key FKs:
- `workflow_id` → which template governs this item's stage progression
- `current_stage_id` / `previous_stage_id` → position in that workflow (previous_stage supports instant rollback on "Changes Required")
- `owner_id`, `current_assignee_id`, `requester_id`, `created_by_id` → four distinct people, because "who asked," "who's accountable," and "who has the ball right now" are different questions (this is what makes "pending with" answerable)
- `blocked_by_id` → self-referencing FK to another `work_items.id`, for dependency chains
- `campaign_id` → groups sibling deliverables independent of `job_id` if needed

### 8. `work_item_owners` (M:M, Multi-Owner Support)
Solves Ambiguity #1 from the analysis (parallel vs. sequential vs. collaborative owners) **without hardcoding**:
- `role` column: `PRIMARY`, `COLLABORATOR`, `SUPPORT`, `SEQUENTIAL_NEXT`
- `sequence_order`: only meaningful when the parent `workflow_templates.multi_owner_behavior = 'SEQUENTIAL'`
- `submission_status` per owner: lets the handoff engine check "has everyone submitted?" before advancing a `PARALLEL` task

### 9. `submissions` (1:M from work_items)
Every "Submit for Next Stage" click creates a row here — an immutable snapshot (`submission_data JSONB`) plus who/when. This is what "preserve previous submission" (your Return Rule) depends on: nothing is overwritten, only appended.

### 10. `files` (1:M from work_items, optional link to submissions)
`submission_id` is nullable because a file can be attached to a work item generally, or tied to a specific submission event for traceability.

### 11. `approvals` (1:M from work_items)
One row per approval **decision** (not per pending request — pending state lives on `work_items.approval_status`). `stage_id` records *which* stage's gate this decision closed. `outcome` drives the transition lookup in `workflow_transitions`.

### 12. `po_requests` (0:1 from work_items, standalone lifecycle)
Deliberately loosely coupled (`work_id` nullable, `ON DELETE SET NULL`) because a PO can outlive or be reused independent of a single work item's lifecycle. `vendor_contact_id` → `auth_users`, so vendors are users too (with a `VENDOR` role), not free-text fields — this is what "do not hardcode PO approvers" resolves to: the approver of a PO is found via `approval_authorities` with `work_category = 'po'`.

### 13. `comments` (1:M from work_items)
`type` distinguishes plain discussion from `CHANGE_REQUEST` (which the UI can surface differently) and `APPROVAL_NOTE` (auto-created when an approval decision includes a reason).

### 14. `activity_log` (1:M from work_items) — Audit Trail
Append-only. Every stage change, assignment, deadline edit, block/unblock event lands here with `actor_id`, `change_from`, `change_to`. This table is what makes the Control Tower's "activity history" and compliance audits possible.

### 15. `notifications` (1:M from work_items, 1:M to auth_users)
Decoupled from the notification *sending* mechanism (email/Slack/in-app) via the `channel` column — the schema doesn't care how a notification is delivered, only that it happened and whether it was read.

---

## How This Satisfies "No Hardcoding"

| Requirement | How the schema handles it |
|---|---|
| No hardcoded individual names | Every person reference is a FK to `auth_users.id`, resolved at query time |
| No hardcoded departments | `departments` is a standalone table; work routes via `work_category`, not department name strings |
| No hardcoded approval chains | `approval_authorities` + `workflow_transitions` — both editable data |
| No hardcoded PO approvers | PO approval routes through the same `approval_authorities` table (`work_category = 'po'`) |
| No hardcoded deadlines | `stage_sla_config` (per stage + priority) computes `stage_deadline`; nothing is a literal date in code |

## What Still Needs a Decision From You

The schema supports all three multi-owner modes and both PO/no-PO branches, but **someone must populate**:
1. At least one row in `workflow_templates` + its `workflow_stages` + `workflow_transitions` (a working default workflow)
2. `approval_authorities` rows mapping your real approvers (Vijaya, Atampreet, Parul, Akshay) to `work_category` values
3. `user_roles` → `user_role_assignments` for your 15 team members

I'll generate these as **seed data** (not schema) in the import script — that keeps the distinction clean between "structure" (this file) and "configuration" (data your admin can edit later).
