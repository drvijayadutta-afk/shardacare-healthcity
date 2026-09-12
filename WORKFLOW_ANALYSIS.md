# Marketing Workflow Control Tower - Analysis & Design

## Executive Summary

Based on analysis of the current job list (30 jobs, 43 tasks, 15 team members) and your standard workflow definition, this document provides:

1. ✓ Analysis of existing work list patterns
2. ✓ Recurring workflow patterns identified
3. ✓ Database fields required
4. ✓ User roles and permissions matrix
5. ✓ Workflow stages with SLAs
6. ✓ Automatic handoff rules
7. ✓ Identified ambiguities
8. ✓ Technical architecture
9. ✓ Database schema design
10. ✓ Implementation plan

---

## 1. ANALYSIS OF EXISTING WORK LIST

### Current State Snapshot
- **Total Jobs:** 30 marketing/branding projects
- **Total Tasks:** 43 discrete work items
- **Team Members:** 15 people
- **Status Distribution:**
  - In Progress: 28 tasks (65%)
  - Closed/Completed: 7 tasks (16%)
  - Blocked/Pending Handoff: 8 tasks (19%)

### Work Item Distribution by Category
```
Print & Collateral:        8 jobs (27%)
Branding & Design:         7 jobs (23%)
Marketing Campaigns:       6 jobs (20%)
Video & Content:           4 jobs (13%)
Photography/Lab:           2 jobs (7%)
Tracking/Coordination:     2 jobs (7%)
Document Review:           1 job  (3%)
```

### Current Status Patterns
| Status | Count | Meaning | Current Bottleneck? |
|--------|-------|---------|-------------------|
| `in_progress` | 28 | Work underway by creator | Yes - unclear what's next |
| `closed` | 7 | Completed work | No |
| `sent_to_approval` | 1 | Awaiting department approval | Yes |
| `approval_pending` | 1 | Awaiting decision | Yes |
| `sent_for_printing` | 1 | With vendor | Yes |
| `sent_to_review` | 1 | Internal review stage | Yes |
| `vendor_aligned` | 1 | Vendor contracted | Yes |
| `recce_pending` | 1 | Awaiting site visit | Yes |
| `costing_sent` | 1 | Awaiting budget approval | Yes |
| `pending` | 1 | Blocked (unspecified) | Yes |

**Key Finding:** 65% of work is marked "in_progress" but lacks clarity on:
- Who is working on it right now?
- What's blocking progress?
- Is it waiting on someone else?
- What's the next action?

---

## 2. RECURRING WORKFLOW PATTERNS

### Pattern 1: Simple Linear Workflow (22 tasks)
```
Creator/Designer → (Complete) → Closed
```
**Examples:**
- Dibrugarh Flyer (Vivek)
- Sandwich Posters (Jaggi)
- Sales emailer Neuro Fast (Love + Shreyak)
- YK sir Grandson video (Anshika + Vidisha)

**Characteristic:** No intermediate approvals mentioned in current data.

**Issue:** These should follow standard workflow but data shows direct completion. Either:
- They completed without formal approval, OR
- Approval steps are implicit/missing from current job list, OR
- They skip approval for low-risk work

---

### Pattern 2: Creator → Single Approver Workflow (3 tasks)
```
Creator → Approval Authority → Closed
```

**Current Examples:**
- Maxwell brochure (Vivek, Vijaya) → sent to Akshay for approval
- Wall of fame (Jaggi) → approval pending with Parul
- KTP Hoarding (Nasir) → sent to Nirmal and MS for review

**Issue:** Approver is sometimes the designer, sometimes separate. Current data conflates creator/reviewer roles.

---

### Pattern 3: Designer → Vendor → Execution Workflow (2 tasks)
```
Designer → Vendor Alignment → (Recce/Costing) → Production
```

**Current Examples:**
- Dr. Vivek Yadav Clinic (Nirmal) → vendor aligned for 11th sept → recce pending
- Dr. Lipi Clinic (Nirmal) → vendor aligned

**Issue:** No visibility into when vendor work completes. Missing final approval gate.

---

### Pattern 4: Multi-Stage Production Workflow (2 tasks)
```
Designer → Approval → Print Vendor → Final Approval → Release
```

**Current Examples:**
- Stroke booklet (Atampreet + Vijaya) → maker-checker approval → sent for printing
- Dr. Pallav Mishra collateral (Love + Nirmal) → in progress

**Issue:** "Maker-checker" approval pattern present but not explicitly defined in workflow.

---

### Pattern 5: Campaign with Multiple Deliverables (4 tasks with 5 variants each)
```
Campaign Lead → Content (5 types) → All parallel or sequential?
```

**Current Examples:**
- Mother & Child Camp: newspaper ad, Whatsapp, Emailer, Flyer, Meta creative (all in_progress)
- Sepsis Week: Banners, digital standees, selfie booth, emailer

**Issue:** Unclear if these 5 deliverables are:
- All parallel streams (5 owners working simultaneously)?
- Sequential (one after another)?
- Dependent on each other?

---

### Pattern 6: Costing/Budget Review Workflow (1 task)
```
Designer → Costing Submission → Budget Approval → Vendor → Production
```

**Current Examples:**
- Green Belt Design (no owner) → costing sent to purchase

**Issue:** "Costing sent" is not a standard workflow stage. This should follow PO workflow.

---

### Pattern 7: Multiple Owners = Parallel or Sequential?
```
13 of 43 tasks (30%) have multiple owners
```

**Current Examples:**
- NABH Signages: Nirmal + Mudit + Shreyak (3 people)
- Lab images: Himanshu + Vidisha (2 people)
- Physio requirements: Jaggi + Vijaya (2 people)

**Critical Question:** Does "multiple owners" mean:
- A) Parallel work (all work simultaneously)?
- B) Sequential (one hands off to next)?
- C) Collaborative (shared accountability)?

**Current Data:** All marked same status, suggesting parallel or collaborative.

---

## 3. DATABASE FIELDS REQUIRED

### Core Work Item Fields
Every task must capture:

#### Identity & Tracking
- `work_id` (UUID) - Unique identifier
- `job_id` (FK) - Parent job reference
- `task_name` - Human-readable title
- `task_description` - Detailed description
- `workflow_type` - Enum: "standard", "campaign_multi", "vendor", "simple", "costing_required"

#### Ownership & Assignment
- `requester_id` (FK) - Who asked for this work
- `owner_id` (FK) - Primary owner
- `co_owners` (JSON array) - Additional owners if parallel/collaborative
- `current_assignee_id` (FK) - Who it's assigned to right now
- `previous_owner_id` (FK) - For backtrack on "Changes Required"

#### Workflow & Status
- `current_stage` - Enum: Request, Brief, Content, Design, Internal Review, Dept Approval, PO/Procurement, Production, Final Approval, Release, Completed
- `previous_stage` - For quick backtrack
- `status` - Enum: Not Started, In Progress, Submitted, Approved, Changes Required, Rejected, Blocked, On Hold, Completed
- `substatus` - Clarification field (e.g., "waiting_on_vendor", "awaiting_cost_approval", "recce_pending")

#### Deadline & SLA
- `deadline` - Target completion date
- `stage_deadline` - Deadline for current stage (auto-calculated from SLA)
- `days_remaining` - Calculated field (deadline - today)
- `is_overdue` - Boolean
- `overdue_days` - If applicable

#### Dependencies & Blocks
- `depends_on_ids` (JSON array) - Other work IDs this task depends on
- `blocked_by_id` - If blocked, which work item or external factor
- `blocker_type` - Enum: "approval", "vendor", "budget", "external", "info_needed", "other"
- `blocker_owner_id` - Who can unblock this

#### Approvals
- `approval_required` - Boolean
- `approval_stage` - Which stage requires approval
- `approver_id` (FK) - Who approves (can be multiple)
- `approval_status` - Enum: Not Required, Pending, Approved, Changes Required, Rejected
- `approval_reason` - If Changes Required or Rejected, why?
- `approval_date` - When was approval given

#### PO/Procurement
- `po_required` - Boolean
- `po_stage` - Which stage (per workflow)
- `po_id` - Link to PO if created
- `procurement_owner_id` - Who manages procurement
- `po_status` - Enum: Not Required, Not Started, In Progress, Submitted, Approved, Released

#### Attachments & Submission
- `attachment_required` - Boolean
- `attachment_type` - Expected file type(s)
- `submitted_attachments` (JSON) - Array of attachment metadata
- `submission_count` - How many times submitted (to track iterations)
- `current_submission_id` (FK) - Link to current submission record

#### Notifications & Handoffs
- `notify_on_stage_change` - Boolean
- `notify_on_approval` - Boolean
- `last_notified_date` - When was assignee last notified
- `handoff_timestamp` - When was work handed off to current assignee
- `handoff_user_id` - Who performed the handoff

#### Tracking & Audit
- `priority` - Enum: Critical, High, Medium, Low
- `created_by_id` (FK)
- `created_date` - Timestamp
- `updated_date` - Timestamp
- `completed_date` - When marked as Complete
- `deleted_date` - Soft delete support
- `activity_log_id` (FK) - Link to detailed activity history

#### Campaign-Specific (if applicable)
- `campaign_id` (FK) - If part of campaign
- `deliverable_type` - e.g., "email", "flyer", "social_post", "banner"
- `deliverable_sequence` - Order within campaign (1 of 5, etc.)
- `release_date` - When should this go live
- `channels` (JSON) - Where will this be published

---

## 4. USER ROLES & PERMISSIONS MATRIX

### Role Hierarchy

#### 1. **Admin** (System Administrators)
- Manage users and permissions
- Configure workflow stages and SLAs
- Set approval authorities
- View all work items and audit logs
- Create system-wide notifications

**Permissions:**
- ✓ Create work items
- ✓ Modify any work item
- ✓ Approve any work
- ✓ Override workflow rules
- ✓ Access all reports
- ✓ Manage team members

---

#### 2. **Workflow Manager** (Marketing Director / Operations Lead)
- Oversee all active work
- Configure workflows per job type
- Manage team assignments
- Escalate blocked items
- Generate reports and dashboards

**Permissions:**
- ✓ View all work items
- ✓ Reassign work between team members
- ✓ Modify deadlines
- ✓ Mark items as blocked/hold
- ✓ Access dashboard/KPIs
- ✓ Run reports
- ✗ Cannot override approvals

---

#### 3. **Approver** (Department Head / Subject Matter Expert)
- Approve work at approval stages
- Request changes or reject
- Add approval comments
- Cannot modify work content

**Examples from team:** Vijaya, Atampreet, Parul, Akshay

**Permissions:**
- ✓ View assigned work for approval
- ✓ Approve/Reject/Request Changes
- ✓ Add comments
- ✓ Set condition for approval
- ✗ Cannot edit work
- ✗ Cannot create work

---

#### 4. **Creator/Designer** (Content Creators, Designers)
- Own work item through completion
- Submit work for next stage
- Respond to change requests
- Cannot approve own work

**Examples from team:** Jaggi, Nirmal, Love, Shreyak, Nasir, Vivek, Anshika, etc.

**Permissions:**
- ✓ View own work items
- ✓ Update work in assigned stage
- ✓ Upload attachments
- ✓ Submit for next stage
- ✓ View feedback/change requests
- ✗ Cannot approve
- ✗ Cannot reassign
- ✗ Cannot skip stages

---

#### 5. **Coordinator** (Campaign Managers, Project Leads)
- Create and manage work items
- Assign to creators
- Track progress
- Escalate delays
- Cannot perform creative work

**Examples from team:** Vivek (Campaign Manager), Nishith (Campaign Coordinator)

**Permissions:**
- ✓ Create work items
- ✓ View all assigned work
- ✓ Assign to team members
- ✓ Update deadlines (within reason)
- ✓ Change priority
- ✓ Mark as blocked (with reason)
- ✓ Generate reports
- ✗ Cannot approve
- ✗ Cannot modify work content

---

#### 6. **Requestor/Stakeholder** (Department Heads, Partners)
- Submit requests
- View status of requested work
- May not have system login (via email updates)

**Permissions:**
- ✓ View own requested work
- ✓ Receive status emails
- ✗ Cannot modify work
- ✗ Cannot see others' requests

---

### Cross-Functional Roles

#### **Procurement Lead** (for PO workflows)
- Manage PO requests
- Coordinate with vendors
- Approve budget
- Release POs

#### **Vendor Coordinator** (for vendor workflows)
- Track vendor engagement
- Schedule recces/site visits
- Manage vendor deliverables
- Quality check from vendors

---

## 5. WORKFLOW STAGES & SLAs

### Standard Workflow: 11 Stages

```
1. REQUEST
   ↓
2. BRIEF
   ↓
3. CONTENT (for copy-heavy work)
   ↓
4. DESIGN
   ↓
5. INTERNAL REVIEW
   ↓
6. DEPARTMENT APPROVAL
   ↓
7. PO/PROCUREMENT (conditional: if po_required=true)
   ↓
8. PRODUCTION
   ↓
9. FINAL APPROVAL
   ↓
10. RELEASE
   ↓
11. COMPLETED
```

### Stage Definitions & SLA Recommendations

| # | Stage | Owner Role | Activities | SLA | Deliverables | Next Stage |
|---|-------|-----------|-----------|-----|--------------|-----------|
| 1 | **REQUEST** | Requestor/Coordinator | Submit request form, attach brief | 0 days | - Work order form - Requirements doc | BRIEF |
| 2 | **BRIEF** | Coordinator | Review scope, clarify requirements, assign creator | 1-2 days | - Clarified requirements - Resource allocation - Start date | CONTENT or DESIGN* |
| 3 | **CONTENT** | Content Creator | Write copy, outline, messaging | 2-5 days | - Copy document - Approval form | DESIGN |
| 4 | **DESIGN** | Designer | Create visual/layout/mockup | 3-7 days | - Design file - Source files - High-res export | INTERNAL REVIEW |
| 5 | **INTERNAL REVIEW** | Internal Reviewer | QA checks, brand compliance, tech check | 1-2 days | - Review checklist - Comments/feedback | DEPARTMENT APPROVAL or back to DESIGN |
| 6 | **DEPARTMENT APPROVAL** | Approver (Vijaya/Atampreet/Parul/Akshay) | Formal approval or request changes | 1-3 days | - Approval sign-off OR change request | PO stage (if po_required=Y) OR PRODUCTION |
| 7a | **PO REQUEST** (if po_required=true) | Coordinator | Prepare PO, cost estimate, vendor details | 1-2 days | - PO draft - Vendor quote - Budget approval form | PO APPROVAL |
| 7b | **PO APPROVAL** (if po_required=true) | Finance/Manager | Review and approve PO | 1-2 days | - PO approved - Budget confirmed | PO RELEASED |
| 7c | **PO RELEASED** (if po_required=true) | Procurement Lead | Send to vendor, confirm receipt | 0 days | - Vendor confirmation - PO tracking | PRODUCTION |
| 8 | **PRODUCTION** | Designer/Vendor/Producer | Execute approved design, produce content | 2-14 days (varies) | - Final files - Production proof - Quality check | FINAL APPROVAL |
| 9 | **FINAL APPROVAL** | Approver | Sign-off on final deliverable | 1-2 days | - Final approval OR request last changes | RELEASE or back to PRODUCTION |
| 10 | **RELEASE** | Coordinator/Channel Manager | Publish, upload, deploy, send | 0-1 days | - Publication confirmation - Release notes | COMPLETED |
| 11 | **COMPLETED** | (System) | Archive, close out | 0 days | - Completion timestamp - Final activity log | - |

### Conditional Paths

#### Path A: Content + Design Required
```
REQUEST → BRIEF → CONTENT → DESIGN → INTERNAL REVIEW → DEPARTMENT APPROVAL → [PO] → PRODUCTION → FINAL APPROVAL → RELEASE → COMPLETED
```
**Typical for:** Campaigns with copy (emails, ads, social posts)

#### Path B: Design Only (No Content Stage)
```
REQUEST → BRIEF → DESIGN → INTERNAL REVIEW → DEPARTMENT APPROVAL → [PO] → PRODUCTION → FINAL APPROVAL → RELEASE → COMPLETED
```
**Typical for:** Flyers, banners, signage (visual only)

#### Path C: Simple Work (Minimal Approval)
```
REQUEST → BRIEF → DESIGN → INTERNAL REVIEW → RELEASE → COMPLETED
```
**Typical for:** Straightforward collateral, when approval is implicit

---

## 6. AUTOMATIC HANDOFF RULES

### Rule 1: Standard Submit → Auto-Advance
**When:** User clicks "Submit for Next Stage"

**Action Chain:**
```
1. Validate required fields (check workflow config)
   - If validation fails → Block submission, show errors
   
2. Validate attachments
   - If expected attachment missing → Block, request upload
   
3. Save submission record
   - timestamp = now
   - submitted_by = current_user
   - submission_data = form data snapshot
   
4. Update work item
   - current_stage = next_stage (from workflow config)
   - status = "Submitted" (intermediate state)
   - previous_stage = prior stage
   - previous_owner_id = current owner
   
5. Determine next_assignee
   - Query workflow_config[workflow_type][next_stage]
   - If "approver_role" → Query approval_authority config
   - If "creator_role" → Use coordinator's assignment
   - If "vendor" → Use vendor contact
   
6. Create task assignment
   - assignee_id = next_assignee
   - current_assignee_id = next_assignee
   - stage_deadline = today + SLA_for_stage
   - status = "Pending" → "In Progress" (when assignee first opens)
   
7. Add activity log entry
   - "Submitted by [Name] on [Date]"
   - "Assigned to [Next Name]"
   - Include submission comment if provided
   
8. Send notification
   - Email to new assignee
   - Subject: "[URGENT] New work item assigned: [Task Name]"
   - Include: Task description, deadline, deadline, submission notes
   - Link to work item
   - Mention any change requests or conditions
   
9. Update dashboard
   - Remove from submitter's "Action Items"
   - Add to assignee's "Pending Review" or "To Do"
   - Recalculate team KPIs
```

**Validation Checklist:**
```json
{
  "REQUEST": {
    "required_fields": ["requester_name", "requester_email", "task_name", "deadline"],
    "attachment_required": true,
    "attachment_types": ["pdf", "doc", "docx", "jpg", "png"]
  },
  "DESIGN": {
    "required_fields": ["design_file", "description"],
    "attachment_required": true,
    "attachment_types": ["psd", "ai", "figma_link", "pdf"]
  },
  "DEPARTMENT_APPROVAL": {
    "required_fields": ["approver_id"],
    "attachment_required": false
  }
}
```

---

### Rule 2: Conditional Branching Based on Approval Outcome

#### 2A: Approved → Continue
```
current_stage = "Department Approval"
approval_outcome = "Approved"

→ IF po_required = TRUE
     next_stage = "PO Request"
  ELSE
     next_stage = "Production"
     
→ Move work item to next stage
→ Assign to appropriate owner
→ Continue workflow
```

#### 2B: Changes Required → Rollback
```
current_stage = "Department Approval"
approval_outcome = "Changes Required"

→ previous_stage = prior stage where work was created (usually "Design")
→ rollback_to_stage = previous_stage
→ current_assignee = previous_owner_id
→ status = "Changes Required"
→ preservation:
     - Keep all prior submissions
     - Add "Submission History" link
     - Display change request comments prominently
     
→ Activity log: "[Approver] requested changes: [Reason]"
→ Notify previous owner: "Changes requested on [Task]. Review: [Link]"
→ Previous owner can see:
     - Original approved design
     - Specific change requests
     - Revision deadline (e.g., 24 hours)
```

#### 2C: Rejected → Escalate
```
current_stage = "Department Approval"
approval_outcome = "Rejected"

→ status = "Rejected"
→ escalate_to = Manager/Workflow Manager
→ Activity log: "[Approver] rejected: [Reason]"
→ Send escalation alert to Manager
→ Options presented to Manager:
     a) Reassign to different designer
     b) Return to Brief stage for rethink
     c) Close as Not Viable
```

---

### Rule 3: Multi-Owner Handoff

**When:** Task has multiple owners (e.g., Nirmal + Mudit + Shreyak)

**Configuration Options:**

#### Option A: Parallel Work
```
Task: "NABH Signages design"
Owners: Nirmal, Mudit, Shreyak

Stage: DESIGN
Workflow: PARALLEL

→ All three get task assigned simultaneously
→ Each has independent sub-tasks OR shared ownership
→ Submission requirement: ALL must submit to advance
→ If ANY submits early:
     - Status = "Partially Submitted"
     - Notify others: "Waiting on [Names] to submit"
     - Deadline warning sent to laggards after 24 hours
     
→ When ALL submitted:
     - Merge submissions into one work item
     - Move to next stage with consolidated submission
     - Credit all contributors in activity log
```

#### Option B: Sequential Hand-Off
```
Task: "Lab images - captured then edited"
Owners: Himanshu → Vidisha

Stage: DESIGN
Workflow: SEQUENTIAL

→ Assign to Himanshu first
→ When Himanshu submits:
     - Auto-assign to Vidisha
     - Include Himanshu's work as reference
     - Context: "Himanshu completed: [outputs]"
     
→ Vidisha can see:
     - Prior stage's work
     - Time spent by prior owner
     - Any change requests
```

#### Option C: Lead + Support
```
Task: "Stroke booklet production"
Owners: Atampreet (Lead), Vijaya (Support)

Workflow: COLLABORATIVE

→ Atampreet = primary assignee (gets notifications)
→ Vijaya = added as "cc" or "can view"
→ Only Atampreet's submission advances workflow
→ Vijaya can comment/collaborate but isn't gating
→ Activity log shows: "Lead: Atampreet | Support: Vijaya"
```

**Configuration stored in workflow_config:**
```json
{
  "job_type": "branding",
  "multi_owner_behavior": "PARALLEL" | "SEQUENTIAL" | "COLLABORATIVE"
}
```

---

### Rule 4: Vendor Workflow Special Case
```
current_stage = "PRODUCTION"
work_type = "with_external_vendor"

→ Assign to: vendor_contact_id
→ Set status: "With Vendor"
→ Open communication channel (email, portal)
→ Create expected delivery date from deadline
→ Automatic escalation if no update for 3 days
→ When vendor submits deliverable:
     - Auto-move to "Final Approval"
     - Assign to internal approver
     - Include vendor's delivery note
     
→ If delivery late:
     - Alert manager after SLA missed
     - Show recalculated delivery impact
     - Option to extend or escalate
```

---

### Rule 5: Deadline SLA Auto-Reset on Rollback
```
When "Changes Required" moves work back to previous stage:

current_stage = "DESIGN"
stage_deadline = 7 days ago (MISSED)
approval_outcome = "Changes Required" (moved back to DESIGN)

→ New stage_deadline = today + ORIGINAL_SLA (e.g., today + 3 days)
→ Rationale: Extra time for revisions, not punishing for prior delays
→ Activity log: "Deadline reset to [date] due to revision request"
```

---

## 7. IDENTIFIED AMBIGUITIES REQUIRING CONFIGURATION

### Ambiguity 1: Multi-Owner Task Behavior
**Current State:** 13 tasks (30%) have multiple owners. Current data doesn't clarify:

- Are they working in **parallel** (all simultaneously)?
- Are they working **sequentially** (one after another)?
- Or are they **collaborative** (shared accountability)?

**Current Conflicts:**
- "NABH Signages: Nirmal/Mudit/Shreyak" - all marked same status (in_progress)
- "Lab images: Himanshu/Vidisha" - suggests video + photo (likely sequential)
- "Maxwell brochure: Vivek/Vijaya" - designer + approver (not collaborative in creative sense)

**Solution:** Add **Workflow Configuration Layer**
```
Each job_type or task_type needs:
{
  "workflow_type": "standard",
  "multi_owner_mode": "PARALLEL" | "SEQUENTIAL" | "COLLABORATIVE",
  "submission_requirement": "ALL_MUST_SUBMIT" | "LEAD_SUBMITS_ONLY" | "FIRST_ONE_SUBMITS"
}
```

---

### Ambiguity 2: Approval Authority Assignment
**Current State:**
- Wall of fame → "Parul ma'am" (specific person)
- Maxwell brochure → "Akshay" (specific person)
- KTP Hoarding → "Nirmal and MS" (unclear who is approver vs doer)
- Green belt → No specific approver mentioned

**Question:** How is approval authority determined?
- By work type? (e.g., all branding needs Marketing Manager)
- By department? (e.g., Clinic work needs Dr. Clinic Owner)
- By budget threshold? (e.g., >50k rupees needs CFO)
- By job category? (e.g., Campaigns need Director)

**Current Team Approvers Identified:**
- Vijaya (Content/Approval)
- Atampreet (Approval Authority)
- Parul (Approval Authority)
- Akshay (Approval Authority)

**Problem:** No mapping of work type → approver.

**Solution:** Create **Approval Authority Configuration Matrix**
```json
{
  "approval_matrix": [
    {
      "work_type": ["campaign", "email", "social"],
      "value_threshold_min": 0,
      "value_threshold_max": 999999,
      "approver_role_id": "approval_authority",
      "specific_approver_options": ["Vijaya", "Atampreet"]
    },
    {
      "work_type": ["branding", "clinic"],
      "value_threshold_min": 0,
      "approver_role_id": "department_head",
      "specific_approver_options": ["Parul", "Akshay"]
    },
    {
      "work_type": "po_request",
      "value_threshold_min": 100000,
      "approver_role_id": "finance_head"
    }
  ]
}
```

---

### Ambiguity 3: Content vs. Design Stage Separation
**Current State:**
- Mother & Child campaign has 5 deliverables: newspaper ad, Whatsapp, Emailer, Flyer, Meta creative
- All listed as "in_progress" but unclear if they're:
  - All in DESIGN stage?
  - Some in CONTENT (copy), some in DESIGN (visual)?
  - Separate parallel workflows?

**Question:** Should campaigns create:
- A) One parent task with 5 sub-tasks?
- B) Five separate independent tasks?
- C) One task per deliverable type?

**Current Problem:** "Mother & child camp campaign" as single parent, but 5 task fields suggest multiple deliverables.

**Solution:** Add **Campaign/Deliverable Structure**
```json
{
  "parent_job": "Mother & Child Camp Campaign",
  "workflow_mode": "CAMPAIGN_MULTI",
  "deliverables": [
    {
      "id": "deliverable_001",
      "type": "newspaper_ad",
      "owner": "Vivek",
      "requires_content_stage": true,
      "deadline": "2026-09-26"
    },
    {
      "id": "deliverable_002",
      "type": "whatsapp_message",
      "owner": "Vivek",
      "requires_content_stage": true,
      "deadline": "2026-09-26"
    }
  ]
}
```

---

### Ambiguity 4: Vendor vs. Production Stage Confusion
**Current State:**
- Stroke booklet: in DESIGN → sent_for_printing (which stage?)
- Dr. Vivek Yadav Clinic: vendor_aligned → recce_pending (what comes after recce?)
- Dr. Lipi Clinic: vendor_aligned (then what?)

**Question:** How many stages between approving work and it reaching audience?

**Current Data Suggests:**
- DESIGN → APPROVAL → (PRODUCTION=Printing) → RELEASE

**Or:**
- DESIGN → APPROVAL → VENDOR_ALIGNMENT → PRODUCTION → FINAL_QUALITY_CHECK → RELEASE

**Problem:** No visibility into when vendor work completes or who QCs it.

**Solution:** Add **Production Workflow Substages**
```json
{
  "stage": "PRODUCTION",
  "substages": {
    "vendor_engagement": {
      "status": "vendor_aligned",
      "owner": "vendor_coordinator",
      "expected_completion": "deadline"
    },
    "production_execution": {
      "status": "in_production",
      "owner": "vendor",
      "deliverable_checkpoint": "partial_proof"
    },
    "quality_check": {
      "status": "qa_review",
      "owner": "internal_qa_lead",
      "required_before": "final_approval"
    }
  }
}
```

---

### Ambiguity 5: "Pending" Status - Too Vague
**Current State:**
- Cardiac Campaign has one task marked "pending"
- No explanation of what it's pending on

**Question:** Is it pending:
- Approval?
- Vendor delivery?
- Budget?
- Information from requestor?
- Something else?

**Solution:** Replace "pending" with **substatus codes**
```
pending_approval
pending_vendor
pending_budget
pending_info_from_requestor
pending_external_dependency
blocked_by_[specific_other_task_id]
```

---

### Ambiguity 6: SLA Variations by Urgency
**Current Data:**
- Most tasks have 1-2 day deadlines (fast)
- Some have 2-week deadlines
- One says "next week" (vague)

**Question:** How are SLAs determined?
- By workflow stage (Design always 3 days)?
- By priority (High priority = 2 days, Low = 5 days)?
- By job category (Campaigns = 1 week, Branding = 2 weeks)?
- Custom per task?

**Current Data Suggests:**
- Campaign work: 1-2 day turnaround (tight)
- Branding/Clinic work: 2-3 day turnaround (more time)

**Solution:** Create **SLA Configuration by Workflow + Priority**
```json
{
  "stage_sla_matrix": {
    "DESIGN": {
      "CRITICAL": 2,
      "HIGH": 3,
      "MEDIUM": 5,
      "LOW": 7
    },
    "INTERNAL_REVIEW": {
      "CRITICAL": 1,
      "HIGH": 1,
      "MEDIUM": 2,
      "LOW": 3
    }
  }
}
```

---

### Ambiguity 7: Maker-Checker Pattern
**Current Data:**
- Stroke booklet: "maker-checker approval" → sent for printing
- Not defined in standard workflow

**Question:** Is maker-checker:
- A second internal review before printing?
- Part of Internal Review stage?
- A separate Quality Assurance stage?

**Who is maker vs. checker?** Unclear from current data.

**Solution:** Define **Maker-Checker as explicit sub-stage**
```json
{
  "stage": "INTERNAL_REVIEW",
  "substage": "maker_checker",
  "maker": "primary_creator",
  "checker": "secondary_reviewer",
  "both_must_approve": true,
  "can_comment": true,
  "can_request_changes": true,
  "can_reject": false
}
```

---

## 8. TECHNICAL ARCHITECTURE

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    USER INTERFACE LAYER                      │
├─────────────────────────────────────────────────────────────┤
│  Dashboard │ Work Items │ Assignments │ Reports │ Settings  │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                   API/BUSINESS LOGIC LAYER                   │
├─────────────────────────────────────────────────────────────┤
│ ▪ Workflow Engine                                            │
│ ▪ Handoff Automation                                         │
│ ▪ Approval Logic                                             │
│ ▪ Notification Service                                       │
│ ▪ Reporting Engine                                           │
│ ▪ SLA Calculator                                             │
│ ▪ Validation Service                                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                    DATABASE LAYER                            │
├─────────────────────────────────────────────────────────────┤
│ ▪ Work Items                                                 │
│ ▪ Submissions & Versions                                     │
│ ▪ Users & Permissions                                        │
│ ▪ Workflow Config                                            │
│ ▪ Activity Log                                               │
│ ▪ Notifications Log                                          │
└─────────────────────────────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│              EXTERNAL INTEGRATIONS                           │
├─────────────────────────────────────────────────────────────┤
│ ▪ Email Service (notifications)                              │
│ ▪ File Storage (AWS S3 for attachments)                      │
│ ▪ Slack Integration (optional)                               │
│ ▪ Calendar/Meeting Integration (optional)                    │
│ ▪ Analytics (Google Analytics)                               │
└─────────────────────────────────────────────────────────────┘
```

### Component Breakdown

#### 1. **Workflow Engine**
- Reads workflow_config for work item type
- Determines next stage based on current stage + approval outcome
- Enforces stage transitions
- Manages conditional paths (PO required or not, etc.)

#### 2. **Handoff Automation**
- Triggered on submission
- Validates required fields & attachments
- Determines next assignee from config
- Creates task assignment record
- Updates status fields
- Triggers notification service

#### 3. **Approval Logic**
- Routes work to correct approver
- Enforces approval outcomes (Approved/Changes Required/Rejected)
- Implements rollback on changes requested
- Logs approval decision with timestamp & reason

#### 4. **Notification Service**
- Email on work assignment
- Reminder on overdue items (3 days before deadline)
- Alert when item goes overdue
- Submission confirmation
- Approval decision notification
- Daily digest of "action items"

#### 5. **SLA Calculator**
- Calculates days_remaining based on stage_deadline
- Flags overdue items
- Predicts completion date based on progress
- Identifies bottlenecks (items stuck in one stage)

#### 6. **Dashboard/Reporting**
- Real-time status: What work is active?
- Ownership: Who owns what?
- Workflow stage breakdown: How many at each stage?
- Overdue tracking: Which items are behind?
- Team utilization: Who's overloaded?
- Approval bottlenecks: Which approvers have pending items?
- Time-to-completion trends

---

## 9. DATABASE SCHEMA DESIGN

### Core Tables

#### Table 1: `jobs`
Parent container for a project/campaign.

```sql
CREATE TABLE jobs (
  job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_name VARCHAR(255) NOT NULL,
  job_description TEXT,
  category VARCHAR(100),
  requester_id UUID NOT NULL REFERENCES users(user_id),
  created_date TIMESTAMP DEFAULT NOW(),
  updated_date TIMESTAMP DEFAULT NOW(),
  deleted_date TIMESTAMP,
  INDEX idx_requester (requester_id),
  INDEX idx_category (category)
);
```

---

#### Table 2: `work_items` (Core Table)
Individual tasks/work items.

```sql
CREATE TABLE work_items (
  work_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID NOT NULL REFERENCES jobs(job_id),
  work_name VARCHAR(255) NOT NULL,
  work_description TEXT,
  workflow_type VARCHAR(50) NOT NULL DEFAULT 'standard',
  -- Standard: Request→Brief→Content→Design→...
  -- Campaign: Parent task with deliverables
  -- Vendor: Design→Vendor→Production
  -- Simple: Brief→Design→Release
  
  -- Ownership
  requester_id UUID NOT NULL REFERENCES users(user_id),
  owner_id UUID REFERENCES users(user_id),
  current_assignee_id UUID REFERENCES users(user_id),
  previous_owner_id UUID REFERENCES users(user_id),
  
  -- Workflow Status
  current_stage VARCHAR(50) NOT NULL DEFAULT 'REQUEST',
  -- VALUES: 'REQUEST','BRIEF','CONTENT','DESIGN','INTERNAL_REVIEW',
  -- 'DEPARTMENT_APPROVAL','PO_REQUEST','PO_APPROVAL','PO_RELEASED',
  -- 'PRODUCTION','FINAL_APPROVAL','RELEASE','COMPLETED'
  
  previous_stage VARCHAR(50),
  status VARCHAR(50) NOT NULL DEFAULT 'NOT_STARTED',
  -- VALUES: 'NOT_STARTED','IN_PROGRESS','SUBMITTED','PENDING',
  -- 'APPROVED','CHANGES_REQUIRED','REJECTED','BLOCKED','ON_HOLD','COMPLETED'
  
  substatus VARCHAR(100),
  -- Examples: 'waiting_on_vendor','awaiting_cost_approval','recce_pending'
  
  -- Deadlines
  deadline DATE NOT NULL,
  stage_deadline DATE,
  
  -- Calculated/Derived
  days_remaining INT GENERATED ALWAYS AS (
    CASE WHEN deadline IS NULL THEN NULL
         ELSE (deadline - CURRENT_DATE)
    END
  ) STORED,
  
  is_overdue BOOLEAN GENERATED ALWAYS AS (
    CASE WHEN stage_deadline IS NULL THEN FALSE
         ELSE CURRENT_DATE > stage_deadline
    END
  ) STORED,
  
  -- Priority
  priority VARCHAR(20) NOT NULL DEFAULT 'MEDIUM',
  -- VALUES: 'CRITICAL','HIGH','MEDIUM','LOW'
  
  -- Dependencies
  depends_on_ids JSON,
  -- Example: ["work_id_001","work_id_002"]
  blocked_by_id UUID,
  blocker_type VARCHAR(50),
  -- VALUES: 'approval','vendor','budget','external','info_needed','other'
  blocker_owner_id UUID REFERENCES users(user_id),
  
  -- Approvals
  approval_required BOOLEAN DEFAULT FALSE,
  approval_status VARCHAR(50) DEFAULT 'NOT_REQUIRED',
  -- VALUES: 'NOT_REQUIRED','PENDING','APPROVED','CHANGES_REQUIRED','REJECTED'
  approver_id UUID REFERENCES users(user_id),
  approval_date TIMESTAMP,
  approval_reason TEXT,
  
  -- PO
  po_required BOOLEAN DEFAULT FALSE,
  po_id UUID,
  po_status VARCHAR(50) DEFAULT 'NOT_REQUIRED',
  -- VALUES: 'NOT_REQUIRED','NOT_STARTED','IN_PROGRESS','SUBMITTED','APPROVED','RELEASED'
  procurement_owner_id UUID REFERENCES users(user_id),
  
  -- Attachments
  attachment_required BOOLEAN DEFAULT FALSE,
  attachment_types JSON,
  submission_count INT DEFAULT 0,
  current_submission_id UUID,
  
  -- Campaign (if applicable)
  campaign_id UUID,
  deliverable_type VARCHAR(100),
  deliverable_sequence INT,
  release_date DATE,
  channels JSON,
  
  -- Tracking
  created_by_id UUID NOT NULL REFERENCES users(user_id),
  created_date TIMESTAMP DEFAULT NOW(),
  updated_date TIMESTAMP DEFAULT NOW(),
  completed_date TIMESTAMP,
  deleted_date TIMESTAMP,
  
  -- Notifications
  last_notified_date TIMESTAMP,
  handoff_timestamp TIMESTAMP,
  handoff_user_id UUID REFERENCES users(user_id),
  
  PRIMARY KEY (work_id),
  FOREIGN KEY (owner_id) REFERENCES users(user_id),
  FOREIGN KEY (current_assignee_id) REFERENCES users(user_id),
  FOREIGN KEY (previous_owner_id) REFERENCES users(user_id),
  FOREIGN KEY (approver_id) REFERENCES users(user_id),
  FOREIGN KEY (blocker_owner_id) REFERENCES users(user_id),
  FOREIGN KEY (procurement_owner_id) REFERENCES users(user_id),
  FOREIGN KEY (created_by_id) REFERENCES users(user_id),
  
  INDEX idx_job (job_id),
  INDEX idx_owner (owner_id),
  INDEX idx_current_assignee (current_assignee_id),
  INDEX idx_stage (current_stage),
  INDEX idx_status (status),
  INDEX idx_deadline (deadline),
  INDEX idx_overdue (is_overdue),
  INDEX idx_approver (approver_id),
  INDEX idx_priority (priority),
  INDEX idx_created_date (created_date)
);
```

---

#### Table 3: `work_item_owners` (for Multi-Owner)
Handles parallel/sequential ownership scenarios.

```sql
CREATE TABLE work_item_owners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(work_id),
  owner_id UUID NOT NULL REFERENCES users(user_id),
  role VARCHAR(50),
  -- VALUES: 'PRIMARY','COLLABORATOR','SUPPORT','SEQUENTIAL_NEXT'
  sequence_order INT,
  -- For sequential hand-offs: order of progression
  submission_status VARCHAR(50) DEFAULT 'PENDING',
  -- VALUES: 'PENDING','SUBMITTED','APPROVED'
  submission_date TIMESTAMP,
  
  UNIQUE (work_id, owner_id),
  INDEX idx_work (work_id),
  INDEX idx_owner (owner_id)
);
```

---

#### Table 4: `submissions`
Track each submission (multiple revisions possible).

```sql
CREATE TABLE submissions (
  submission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(work_id),
  submission_number INT NOT NULL,
  submitted_by_id UUID NOT NULL REFERENCES users(user_id),
  submitted_date TIMESTAMP DEFAULT NOW(),
  submission_data JSON,
  -- Snapshot of work_items fields at submission
  notes TEXT,
  -- Submitter's comments
  attachment_ids JSON,
  -- Array of attachment IDs
  
  UNIQUE (work_id, submission_number),
  INDEX idx_work (work_id),
  INDEX idx_submitted_date (submitted_date)
);
```

---

#### Table 5: `attachments`
Store metadata for uploaded files.

```sql
CREATE TABLE attachments (
  attachment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id UUID REFERENCES submissions(submission_id),
  work_id UUID NOT NULL REFERENCES work_items(work_id),
  original_filename VARCHAR(255) NOT NULL,
  stored_filename VARCHAR(255) NOT NULL,
  -- S3 key or path
  file_type VARCHAR(50),
  file_size_bytes INT,
  s3_url VARCHAR(500),
  uploaded_by_id UUID NOT NULL REFERENCES users(user_id),
  uploaded_date TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_work (work_id),
  INDEX idx_submission (submission_id)
);
```

---

#### Table 6: `approvals`
Track approval history and decisions.

```sql
CREATE TABLE approvals (
  approval_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(work_id),
  approver_id UUID NOT NULL REFERENCES users(user_id),
  approval_stage VARCHAR(50) NOT NULL,
  approval_outcome VARCHAR(50) NOT NULL,
  -- VALUES: 'APPROVED','CHANGES_REQUIRED','REJECTED'
  approval_reason TEXT,
  approval_conditions JSON,
  -- Additional notes or conditions
  submitted_at TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_work (work_id),
  INDEX idx_approver (approver_id),
  INDEX idx_stage (approval_stage)
);
```

---

#### Table 7: `activity_log`
Complete audit trail of all actions.

```sql
CREATE TABLE activity_log (
  log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id UUID NOT NULL REFERENCES work_items(work_id),
  action_type VARCHAR(100) NOT NULL,
  -- Examples: 'CREATED','SUBMITTED','APPROVED','REJECTED','ASSIGNED',
  -- 'STAGE_CHANGED','DEADLINE_CHANGED','BLOCKED','UNBLOCKED'
  
  actor_id UUID REFERENCES users(user_id),
  -- Who performed the action
  action_timestamp TIMESTAMP DEFAULT NOW(),
  details JSON,
  -- Flexible details object (varies by action_type)
  change_from VARCHAR(500),
  change_to VARCHAR(500),
  -- For tracking field changes
  
  INDEX idx_work (work_id),
  INDEX idx_actor (actor_id),
  INDEX idx_action_type (action_type),
  INDEX idx_timestamp (action_timestamp)
);
```

---

#### Table 8: `users`
Team members and system users.

```sql
CREATE TABLE users (
  user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(255) NOT NULL UNIQUE,
  full_name VARCHAR(255) NOT NULL,
  role VARCHAR(50) NOT NULL,
  -- VALUES: 'ADMIN','WORKFLOW_MANAGER','APPROVER','CREATOR','COORDINATOR','REQUESTOR'
  
  avatar_url VARCHAR(500),
  phone VARCHAR(20),
  department VARCHAR(100),
  active BOOLEAN DEFAULT TRUE,
  created_date TIMESTAMP DEFAULT NOW(),
  last_login TIMESTAMP,
  
  INDEX idx_email (email),
  INDEX idx_role (role),
  INDEX idx_active (active)
);
```

---

#### Table 9: `workflow_config`
Configuration for workflow stages, SLAs, and rules.

```sql
CREATE TABLE workflow_config (
  config_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_type VARCHAR(50) NOT NULL UNIQUE,
  -- VALUES: 'standard','campaign','vendor','simple'
  
  description TEXT,
  stages JSON NOT NULL,
  -- Array of stage objects:
  -- {
  --   "stage_name": "DESIGN",
  --   "stage_order": 4,
  --   "approver_role": "approver",
  --   "approver_specific": null or "user_id",
  --   "owner_role": "creator",
  --   "sla_days": 3,
  --   "attachment_required": true,
  --   "next_stage_on_approval": "INTERNAL_REVIEW",
  --   "next_stage_on_changes_required": "DESIGN",
  --   "next_stage_on_po_required": "PO_REQUEST",
  --   "next_stage_on_no_po": "PRODUCTION"
  -- }
  
  multi_owner_behavior VARCHAR(50),
  -- VALUES: 'PARALLEL','SEQUENTIAL','COLLABORATIVE'
  
  sla_matrix JSON,
  -- {
  --   "DESIGN": {"CRITICAL": 2, "HIGH": 3, "MEDIUM": 5, "LOW": 7},
  --   "INTERNAL_REVIEW": {"CRITICAL": 1, ...}
  -- }
  
  approval_matrix JSON,
  -- Array of approval routing rules
  
  active BOOLEAN DEFAULT TRUE,
  created_date TIMESTAMP DEFAULT NOW(),
  updated_date TIMESTAMP DEFAULT NOW(),
  
  INDEX idx_workflow_type (workflow_type)
);
```

---

#### Table 10: `notifications`
Track all notifications sent.

```sql
CREATE TABLE notifications (
  notification_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id UUID NOT NULL REFERENCES users(user_id),
  work_id UUID REFERENCES work_items(work_id),
  notification_type VARCHAR(100),
  -- VALUES: 'ASSIGNMENT','APPROVAL_REQUIRED','CHANGES_REQUIRED',
  -- 'OVERDUE_WARNING','OVERDUE','SUBMISSION_RECEIVED','APPROVED'
  
  subject VARCHAR(255),
  message TEXT,
  sent_date TIMESTAMP DEFAULT NOW(),
  read_date TIMESTAMP,
  action_url VARCHAR(500),
  -- Link to work item in UI
  
  INDEX idx_recipient (recipient_id),
  INDEX idx_work (work_id),
  INDEX idx_sent_date (sent_date),
  INDEX idx_read_date (read_date)
);
```

---

## 10. IMPLEMENTATION PLAN

### Phase 1: Foundation (Weeks 1-2)
**Goal:** Build core data structures and basic UI

#### Sprint 1.1: Database Setup
- [ ] Create PostgreSQL schema (all tables above)
- [ ] Create indexes for performance
- [ ] Add sample data from current job list
- [ ] Set up database migrations framework
- [ ] Test data integrity constraints

#### Sprint 1.2: API Foundation
- [ ] Create REST API endpoints for work items (CRUD)
- [ ] Implement user authentication
- [ ] Add role-based access control (RBAC)
- [ ] Create basic error handling & validation
- [ ] Setup logging infrastructure

#### Sprint 1.3: Basic UI
- [ ] Create work item list view (simple table)
- [ ] Create work item detail view
- [ ] Build user login/profile pages
- [ ] Setup navigation/menu structure
- [ ] Basic styling (CSS framework)

---

### Phase 2: Workflow Engine (Weeks 3-4)
**Goal:** Implement workflow logic and automatic handoffs

#### Sprint 2.1: Workflow Configuration
- [ ] Build workflow_config table UI (admin only)
- [ ] Create workflow editor UI
- [ ] Implement workflow loading logic
- [ ] Add validation for workflow definitions
- [ ] Create default workflow templates

#### Sprint 2.2: Stage Transitions
- [ ] Implement stage transition logic
- [ ] Build "Submit for Next Stage" button & logic
- [ ] Create validation service for submissions
- [ ] Implement attachment upload system
- [ ] Add submission history tracking

#### Sprint 2.3: Approval Workflow
- [ ] Implement approval routing logic
- [ ] Build approval decision UI (Approve/Changes/Reject)
- [ ] Create rollback logic for "Changes Required"
- [ ] Implement approval history tracking
- [ ] Add approval comments/reasons

---

### Phase 3: Handoff Automation (Week 5)
**Goal:** Automatic task creation and assignment for next stage

#### Sprint 3.1: Task Assignment
- [ ] Implement next assignee determination logic
- [ ] Create task assignment records
- [ ] Build notification sender
- [ ] Add activity log entries
- [ ] Email template creation

#### Sprint 3.2: Multi-Owner Handling
- [ ] Implement parallel owner logic
- [ ] Implement sequential handoff logic
- [ ] Build submission requirement checks
- [ ] Add team collaboration features
- [ ] Dashboard update for multi-owner tasks

---

### Phase 4: Dashboard & Reporting (Week 6)
**Goal:** Operational visibility and analytics

#### Sprint 4.1: Control Tower Dashboard
- [ ] Active work summary (statuses, stages)
- [ ] Ownership breakdown (who owns what)
- [ ] Overdue items highlighting
- [ ] SLA performance metrics
- [ ] Bottleneck identification

#### Sprint 4.2: Personal Dashboards
- [ ] "My Tasks" for each user
- [ ] "Awaiting My Approval" for approvers
- [ ] "My Team's Work" for managers
- [ ] Calendar/timeline view
- [ ] Deadline alerts

#### Sprint 4.3: Reports
- [ ] Work completion rates (weekly/monthly)
- [ ] Average time per stage
- [ ] Approval turnaround times
- [ ] Team utilization
- [ ] Recurring delay patterns

---

### Phase 5: Notifications & Alerts (Week 7)
**Goal:** Keep team updated without overload

#### Sprint 5.1: Email Notifications
- [ ] Work assignment emails
- [ ] Approval request emails
- [ ] Overdue warnings (3 days before)
- [ ] Overdue alerts (on deadline)
- [ ] Submission confirmation emails

#### Sprint 5.2: In-App Notifications
- [ ] Notification center in UI
- [ ] Mark as read functionality
- [ ] Notification preferences per user
- [ ] Digest mode (daily email summary)
- [ ] Optional Slack integration

---

### Phase 6: Advanced Features (Weeks 8-9)
**Goal:** Enhanced workflow management

#### Sprint 6.1: SLA Management
- [ ] Stage deadline calculation
- [ ] Priority-based SLA variations
- [ ] SLA breach alerts
- [ ] SLA compliance reporting
- [ ] Historical deadline tracking

#### Sprint 6.2: Dependency Management
- [ ] Dependent task blocking
- [ ] Dependency visualization
- [ ] Blockers dashboard
- [ ] Unblock workflow
- [ ] Escalation path for blocked items

#### Sprint 6.3: Campaign Management
- [ ] Campaign parent task creation
- [ ] Multi-deliverable tracking
- [ ] Coordinated deadline management
- [ ] Campaign timeline view
- [ ] Release coordination

---

### Phase 7: Admin & Configuration (Week 10)
**Goal:** System management and customization

#### Sprint 7.1: User Management
- [ ] User CRUD operations
- [ ] Role assignment
- [ ] Permission management
- [ ] Bulk import (from CSV)
- [ ] Active/inactive toggling

#### Sprint 7.2: System Configuration
- [ ] Workflow template management
- [ ] SLA configuration UI
- [ ] Approval matrix management
- [ ] Email template management
- [ ] System settings (timezones, etc.)

#### Sprint 7.3: Data Management
- [ ] Data migration tools (import current jobs)
- [ ] Data export (CSV/Excel)
- [ ] Archive completed work
- [ ] Backup procedures
- [ ] Data cleanup utilities

---

### Phase 8: Testing & Launch (Week 11-12)
**Goal:** Quality assurance and production readiness

#### Sprint 8.1: Testing
- [ ] Unit tests (API endpoints)
- [ ] Integration tests (workflow logic)
- [ ] UI/E2E tests (critical paths)
- [ ] Performance testing (load)
- [ ] Security audit

#### Sprint 8.2: UAT & Training
- [ ] Create user documentation
- [ ] Create admin guides
- [ ] Run UAT with selected team
- [ ] Conduct training sessions
- [ ] Gather feedback & fix issues

#### Sprint 8.3: Launch
- [ ] Production deployment
- [ ] Data migration of existing jobs
- [ ] Soft launch (limited users)
- [ ] Monitor and hotfix
- [ ] Full rollout to team

---

## Implementation Roadmap Timeline

```
WEEK 1-2:   Database + API + Basic UI
WEEK 3-4:   Workflow Engine + Approvals
WEEK 5:     Task Handoff Automation
WEEK 6:     Dashboard & Reports
WEEK 7:     Notifications & Alerts
WEEK 8-9:   Advanced Features (SLA, Dependencies, Campaigns)
WEEK 10:    Admin & Configuration
WEEK 11-12: Testing & Launch

TOTAL:      12 Weeks (3 months)
```

---

## Critical Success Factors

1. **Workflow Clarity:** Resolve ambiguities (Sections 7) before coding
2. **Configuration-Driven:** Don't hardcode workflows; make them configurable
3. **Audit Trail:** Every action must be logged for compliance
4. **Notification Strategy:** Too many emails = ignored; too few = work slips through cracks
5. **Role Clarity:** Clear understanding of who can do what (Section 4)
6. **Performance:** Dashboard must load in <2 seconds even with 1000s of work items
7. **User Adoption:** Ensure team understands workflow benefits; celebrate early wins

---

## Mapping Current Job List to Standard Workflow

### Example 1: Simple Campaign (Cardiac Campaign)
```
Current State:
  Job: Cardiac Campaign
  Tasks:
    - Newspaper ad (hindi & English): closed
    - Whatsapp: closed
    - Emailer: closed
    - Flyer: pending
    - Meta Ad: closed

Standard Workflow Mapping:
  1. REQUEST: Requested by [Requester]
  2. BRIEF: [Coordinator] clarifies scope
  3. CONTENT: [Content Lead] writes copy
  4. DESIGN: [Designer] creates visuals (all 5 items in parallel)
  5. INTERNAL_REVIEW: [Reviewer] checks quality
  6. DEPARTMENT_APPROVAL: [Vijaya] approves
  7. PRODUCTION: [Vendor] prints/distributes (if needed)
  8. FINAL_APPROVAL: [Vijaya] approves final
  9. RELEASE: Published live
  10. COMPLETED: Archived

Current Issues:
  - No visibility into BRIEF, CONTENT, DESIGN phases
  - Some tasks "closed" but unclear if they went through full workflow
  - "Pending" Flyer task: pending what?
  - No approvals documented
```

---

### Example 2: Vendor Workflow (Dr. Vivek Yadav Clinic Branding)
```
Current State:
  Job: Dr. Vivek Yadav Clinic Branding
  Task: (Nirmal) - vendor aligned for 11th sept - recce pending

Standard Workflow Mapping:
  1. REQUEST: Clinic branding requested
  2. BRIEF: Requirements gathered
  3. DESIGN: [Nirmal] creates brand concepts
  4. INTERNAL_REVIEW: [Internal reviewer] approves concepts
  5. DEPARTMENT_APPROVAL: [Approver] approves brand direction
  6. PRODUCTION: Vendor engagement
     - Substage: VENDOR_ALIGNMENT (vendor_aligned)
     - Substage: PRODUCTION_EXECUTION (recce_pending → recce complete)
     - Substage: DELIVERY (vendor delivers assets)
  7. FINAL_APPROVAL: [Approver] approves final brand
  8. RELEASE: Brand launched
  9. COMPLETED: All clinic branded

Current Issues:
  - Workflow visible only from PRODUCTION onwards
  - "Recce pending" is vague - who's doing recce? When's it due?
  - No final approval documented
  - No expected completion date
```

---

## Conclusion

The Marketing Workflow Control Tower will transform your team's work management from:
- **Current:** Scattered job list, unclear handoffs, overdue items going unnoticed
- **Future:** Real-time visibility, automatic routing, SLA tracking, audit trail

The system is built on:
1. **Workflow configuration layer** (not hardcoded)
2. **Clear role definitions** (Admin, Manager, Approver, Creator, Coordinator)
3. **Explicit handoff rules** (who does what, when, with what output)
4. **Audit trail** (every action logged, traceable)
5. **Dashboard visibility** (answering all 11 control tower questions)

Next steps:
1. Review and approve this architecture
2. Clarify remaining ambiguities (Section 7)
3. Get sign-off on workflow stages and SLAs
4. Begin Phase 1 implementation
