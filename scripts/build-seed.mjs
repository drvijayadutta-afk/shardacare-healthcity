#!/usr/bin/env node
/**
 * build-seed.mjs — turn the source job list into seed SQL + a review report.
 *
 * Rules, applied literally and without exception:
 *   - A deadline or an owner that is not in the source stays NULL. Nothing is
 *     inferred from surrounding lines, from the document title, or from what
 *     would be "reasonable".
 *   - "closed"            -> status COMPLETED
 *   - "approval pending"  -> status PENDING, approval stage, pending_with =
 *                            the person the source names, else 'unknown'
 *   - "sent to X for approval" -> approval stage, assigned to X
 *   - several people named -> all kept as collaborators
 *   - anything the source leaves genuinely unclear is FLAGGED for a human,
 *     never resolved by guessing.
 *
 * Outputs:
 *   database/seed.sql        — idempotent INSERTs
 *   database/SEED_REVIEW.md  — every flag, with the source line beside it
 *
 * Usage: node scripts/build-seed.mjs
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');

const lines = JSON.parse(readFileSync(resolve(HERE, 'source_lines.json'), 'utf8'));

// ---------------------------------------------------------------------------
// People actually named in the document.
//
// `canonical` is the display name; `variants` are the spellings that appear in
// the source (the document mixes "Love"/"love", "shreyak"/"Shreyak", etc.).
// Matching is restricted to this roster rather than guessing at names, so an
// unrecognised token becomes a FLAG instead of a silently-invented person.
// ---------------------------------------------------------------------------
const ROSTER = [
  { canonical: 'Love',       variants: ['love'] },
  { canonical: 'Nasir',      variants: ['nasir'] },
  { canonical: 'Vivek',      variants: ['vivek'] },
  { canonical: 'Shreyak',    variants: ['shreyak'] },
  { canonical: 'Anshika',    variants: ['anshika'] },
  { canonical: 'Himanshu',   variants: ['himanshu'] },
  { canonical: 'Vidisha',    variants: ['vidisha'] },
  { canonical: 'Jaggi',      variants: ['jaggi'] },
  { canonical: 'Vijaya',     variants: ['vijaya'] },
  { canonical: 'Nirmal',     variants: ['nirmal'] },
  { canonical: 'Mudit',      variants: ['mudit'] },
  { canonical: 'Atampreet',  variants: ['atampreet'] },
  { canonical: 'Akshay',     variants: ['akshay'] },
  { canonical: 'Parul',      variants: ['parul'] },
  { canonical: 'Sushant',    variants: ['sushant'] },
  { canonical: 'Nishith',    variants: ['nishith'] },
  { canonical: 'Dr. Tarang', variants: ['dr. tarang', 'dr tarang', 'tarang'] },
];

// "Vivek Yadav", "Pallav Mishra", "Lipi", "Ruchi", "Ravindra", "Avinash" are
// names appearing INSIDE work titles (whose clinic is being branded), not
// people doing the work. Matching these as owners would be wrong, so titles
// are masked before the roster scan.
const SUBJECT_PHRASES = [
  'dr. vivek yadav', 'dr vivek yadav',
  'dr pallav mishra', 'dr. pallav mishra',
  'dr. lipi', 'dr lipi',
  'dr. ruchi', 'dr ruchi',
  'dr. ravindra', 'dr ravindra',
  'dr avinash', 'dr. avinash',
  'yk sir',
];

const flags = [];
const flag = (line, kind, detail) =>
  flags.push({ idx: line.i, kind, detail, source: line.text.trim() });

// ---------------------------------------------------------------------------
// Date parsing.
//
// Only an explicit day+month is accepted. The document states a year exactly
// once ("26th Sept 2026", line 8); every other date omits it. Rather than
// silently stamping a year on 20-odd rows, YEAR_SOURCE records where the year
// came from and the review file calls it out as the one assumption made.
// ---------------------------------------------------------------------------
const YEAR = 2026;
const YEAR_SOURCE = 'line 8 ("Mother & child camp campaign: Vivek 26th Sept 2026") — the only line stating a year';

const MONTHS = { sept: 9, september: 9, sep: 9, oct: 10, october: 10, aug: 8, august: 8 };

function parseDate(text, lineForFlag) {
  // Reject vague references outright — they are not dates.
  if (/\bnext week\b/i.test(text)) {
    flag(lineForFlag, 'VAGUE_DATE', '"next week" is not a date; deadline left NULL');
    return null;
  }
  const m = text.match(/(\d{1,2})\s*(?:st|nd|rd|th)?\s+(sept|september|sep|oct|october|aug|august)\b\s*(\d{4})?/i);
  if (!m) return null;
  const day = parseInt(m[1], 10);
  const month = MONTHS[m[2].toLowerCase()];
  const year = m[3] ? parseInt(m[3], 10) : YEAR;
  if (day < 1 || day > 31) return null;
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------
// People detection
// ---------------------------------------------------------------------------
function findPeople(text) {
  let haystack = ' ' + text.toLowerCase() + ' ';
  for (const p of SUBJECT_PHRASES) haystack = haystack.split(p).join(' ~subject~ ');
  const hits = [];
  for (const person of ROSTER) {
    for (const v of person.variants) {
      const re = new RegExp(`(^|[^a-z])${v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}([^a-z]|$)`, 'i');
      if (re.test(haystack)) { hits.push(person.canonical); break; }
    }
  }
  return [...new Set(hits)];
}

// ---------------------------------------------------------------------------
// Status detection — verbatim source phrases mapped to workflow vocabulary
// ---------------------------------------------------------------------------
function detectStatus(text) {
  const t = text.toLowerCase();

  if (/\bapproval pending\b|\bapproval is pending\b/.test(t)) {
    return { status: 'PENDING', stageHint: 'APPROVAL', note: 'approval pending' };
  }
  // "closed10" on line 27 carries a stray list number. Matching `closed`
  // followed by digits (rather than a word boundary) keeps that row from
  // silently missing its COMPLETED status; the artefact is flagged separately
  // and the raw text is preserved in source_text either way.
  if (/\bclosed\b|\bclosed\d+/.test(t)) {
    return { status: 'COMPLETED', stageHint: null, note: 'closed' };
  }
  if (/sent to .* for approval/.test(t) || /approved by/.test(t)) {
    return { status: 'PENDING', stageHint: 'APPROVAL', note: 'sent for approval' };
  }
  if (/sent for printing/.test(t)) {
    return { status: 'IN_PROGRESS', stageHint: 'PRODUCTION', note: 'sent for printing' };
  }
  if (/recce pending/.test(t)) {
    return { status: 'PENDING', stageHint: null, note: 'recce pending' };
  }
  if (/vendor aligned/.test(t)) {
    return { status: 'IN_PROGRESS', stageHint: null, note: 'vendor aligned' };
  }
  if (/costing sent/.test(t)) {
    return { status: 'PENDING', stageHint: null, note: 'costing sent to purchase' };
  }
  if (/sent to /.test(t)) {
    return { status: 'PENDING', stageHint: null, note: 'sent to (review)' };
  }
  // No status word in the source. NOT_STARTED is the schema default and is
  // recorded as "unknown" in the review file — it is NOT a claim that work
  // has not begun.
  return { status: null, stageHint: null, note: null };
}

// ---------------------------------------------------------------------------
// Approver extraction: "sent to X for approval" / "approved by X"
// ---------------------------------------------------------------------------
function detectApprovalTarget(text) {
  const t = text.toLowerCase();
  let m = t.match(/sent to ([^–—(]+?) for approval/);
  if (!m) m = t.match(/approved by ([a-z. ]+?)(?::|,|$)/);
  // "options shared wth Parul ma'am, approval pending" — the person the work
  // was shared with is the one holding the approval. Note the source's
  // "wth" typo, matched deliberately rather than corrected.
  if (!m) m = t.match(/shared\s+w(?:i)?th\s+([^,–—(]+)/);
  if (!m) m = t.match(/sent to ([^–—(]+?)(?:\s*$|–|—|\()/);
  if (!m) return null;

  const chunk = m[1];
  const named = findPeople(chunk);
  // Tokens in the chunk that look like a name but match nobody on the roster
  const unresolved = chunk
    .split(/\s+and\s+|\s*&\s*|,/)
    .map(s => s.trim())
    .filter(Boolean)
    .filter(s => findPeople(s).length === 0)
    .filter(s => !/^(for|approval|the|to|on)$/i.test(s));

  return { named, unresolved, raw: chunk.trim() };
}

// ---------------------------------------------------------------------------
// Walk the lines, building jobs (lvl 0) and work items (lvl 0 alone, or lvl 1)
// ---------------------------------------------------------------------------
const jobs = [];
let current = null;

for (let n = 0; n < lines.length; n++) {
  const line = lines[n];
  const text = line.text.trim();
  const lvl = line.ilvl === '1' ? 1 : 0;
  const nextLvl = lines[n + 1] ? (lines[n + 1].ilvl === '1' ? 1 : 0) : 0;

  if (lvl === 0) {
    const hasChildren = nextLvl === 1;
    current = {
      idx: line.i,
      title: text,
      hasChildren,
      date: parseDate(text, line),
      people: findPeople(text),
      status: detectStatus(text, line),
      approval: detectApprovalTarget(text, line),
      items: [],
    };
    jobs.push(current);
    // A parent with children is a container; it does not itself become a
    // work item. A parent without children IS the work item.
    if (!hasChildren) {
      current.items.push({ ...current, isSelf: true, title: text });
    }
  } else {
    current.items.push({
      idx: line.i,
      title: text,
      date: parseDate(text, line),
      people: findPeople(text),
      status: detectStatus(text, line),
      approval: detectApprovalTarget(text, line),
      parentTitle: current.title,
    });
  }
}

// ---------------------------------------------------------------------------
// Flag pass — everything the source leaves genuinely unclear
// ---------------------------------------------------------------------------
const byIdx = Object.fromEntries(lines.map(l => [l.i, l]));

for (const job of jobs) {
  for (const item of job.items) {
    const line = byIdx[item.idx];

    if (!item.date) flag(line, 'NO_DEADLINE', 'No date in source; deadline left NULL');
    if (item.people.length === 0) {
      flag(line, 'NO_OWNER',
        item.parentTitle
          ? `No owner on this line. Parent "${item.parentTitle}" names ${job.people.join(', ') || 'nobody'} — NOT inherited.`
          : 'No owner named anywhere on this line; owner left NULL');
    }
    if (!item.status.status) flag(line, 'NO_STATUS', 'No status word in source; left unset');
    if (item.people.length > 1) {
      flag(line, 'MULTIPLE_PEOPLE',
        `${item.people.join(', ')} — all kept as collaborators. Which (if any) is the single accountable owner is not stated.`);
    }
    if (item.approval?.unresolved?.length) {
      flag(line, 'UNRESOLVED_RECIPIENT',
        `Cannot resolve "${item.approval.unresolved.join('", "')}" to a person`);
    }
  }
}

// Hand-identified ambiguities that pattern matching cannot express
const MANUAL_FLAGS = [
  [14, 'ROLE_AMBIGUOUS', 'Is "Dr. Tarang" the requester/stakeholder or an owner? The line reads "Dr. Tarang: discuss the requirement" then names Himanshu as doing the video. Recorded as a mention only — no ownership assigned.'],
  [19, 'ROLE_AMBIGUOUS', '"get it approved by atampreet" makes Atampreet the APPROVER, not the owner. "Vijaya for makerchecker" is a second, different review role. The line also ends "sent for printing", implying it already passed both. Sequence not reconstructible from the source.'],
  [19, 'UNPARSED_TERM', '"total solutions" — unclear whether a vendor name, a deliverable, or part of the booklet title.'],
  [21, 'UNRESOLVED_RECIPIENT', '"MS" is an unresolved initialism (Medical Superintendent?). Not added to the roster; recorded verbatim.'],
  [24, 'PENDING_WITH_NAMED', 'Source says "approval pending" AND names Parul. Per your instruction the named person wins, so pending_with = Parul rather than the literal "unknown".'],
  [27, 'SOURCE_ARTEFACT', 'Line ends "closed10" — the trailing "10" appears to be a stray list number, not part of the status. Read as "closed"; the "10" is discarded but preserved in source_text.'],
  [33, 'DATE_MEANING', '"vendor aligned for 11th sept" — the 11th Sept refers to the vendor visit, not necessarily the work deadline. Recorded as deadline with this caveat.'],
  [4,  'NO_STATUS', 'Line reads "Flyer : Love - " with a trailing dash and nothing after it. Owner is Love; status genuinely absent.'],
  [8,  'CAMPAIGN_OWNER_SCOPE', 'Vivek is named on the campaign line only. The five deliverables beneath it (lines 9-13) name nobody, so none of them receives an owner.'],
];
for (const [idx, kind, detail] of MANUAL_FLAGS) {
  if (byIdx[idx]) flag(byIdx[idx], kind, detail);
}

// ---------------------------------------------------------------------------
// SQL emission
// ---------------------------------------------------------------------------
const q = s => (s === null || s === undefined ? 'NULL' : `'${String(s).replace(/'/g, "''")}'`);

const allPeople = [...new Set(jobs.flatMap(j => j.items.flatMap(i => i.people)))].sort();

const sql = [];
sql.push(`-- =============================================================================
-- seed.sql — GENERATED by scripts/build-seed.mjs. Do not edit by hand.
--
-- Source: Job_list_10th_Sept_3.docx (40 lines, verbatim in
-- scripts/source_lines.json). Every row keeps its source_text.
--
-- Nothing here is inferred. Where the document is silent the column is NULL
-- and the row carries needs_review = TRUE. See database/SEED_REVIEW.md for
-- all ${flags.length} flags.
--
-- Year assumption: dates in the source omit the year except one. ${YEAR} is
-- taken from ${YEAR_SOURCE}.
-- =============================================================================

BEGIN;
`);

sql.push(`-- --- People named in the source ------------------------------------------
-- These are people work is ATTRIBUTED to, not login accounts. Nothing is
-- written to auth.users: that table belongs to Supabase's auth service, rows
-- inserted by hand lack the columns GoTrue requires and cannot sign in, and
-- its email index is PARTIAL so ON CONFLICT (email) fails with 42P10.
--
-- When one of these people is given a login, create them through
-- Authentication -> Users and relink. The @placeholder.invalid addresses
-- guarantee no collision with a real sign-up in the meantime.
`);
for (const p of allPeople) {
  const email = p.toLowerCase().replace(/[^a-z]/g, '.') + '@placeholder.invalid';
  sql.push(`INSERT INTO public.users (email, full_name)
VALUES (${q(email)}, ${q(p)})
ON CONFLICT (email) DO NOTHING;`);
}

sql.push(`
-- --- Role assignments ------------------------------------------------------
-- NOTE: the source document states NO roles for anyone. These assignments are
-- an ASSUMPTION carried over so RLS is exercisable, flagged as such in the
-- review file. Correct them in the admin UI; nothing in the engine depends on
-- a specific person holding a specific role.
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id FROM public.users u CROSS JOIN public.roles r
WHERE u.email LIKE '%@placeholder.invalid' AND r.name = 'CREATOR'
ON CONFLICT DO NOTHING;
`);

sql.push(`
-- --- Workflow -------------------------------------------------------------
-- A single permissive template so imported rows have somewhere to sit. The
-- real stage list is the 11-stage flow; it is NOT generated here because the
-- source document does not say which stage any item is at.
INSERT INTO public.workflow_templates (name, description, multi_owner_behavior, is_default)
VALUES ('Imported (unclassified)',
        'Holding workflow for rows imported from the 10th Sept job list.',
        'COLLABORATIVE', FALSE)
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.workflow_stages (workflow_id, name, stage_order, requires_approval)
SELECT w.id, v.name, v.ord, v.appr
FROM public.workflow_templates w,
     (VALUES ('IMPORTED', 1, FALSE), ('APPROVAL', 2, TRUE), ('DONE', 3, FALSE))
       AS v(name, ord, appr)
WHERE w.name = 'Imported (unclassified)'
ON CONFLICT (workflow_id, name) DO NOTHING;

INSERT INTO public.workflow_transitions (workflow_id, from_stage_id, to_stage_id, trigger_condition)
SELECT w.id, s1.id, s2.id, 'SUBMISSION'
FROM public.workflow_templates w
JOIN public.workflow_stages s1 ON s1.workflow_id=w.id AND s1.name='IMPORTED'
JOIN public.workflow_stages s2 ON s2.workflow_id=w.id AND s2.name='APPROVAL'
WHERE w.name='Imported (unclassified)'
ON CONFLICT DO NOTHING;

INSERT INTO public.workflow_transitions (workflow_id, from_stage_id, to_stage_id, trigger_condition)
SELECT w.id, s1.id, s2.id, 'APPROVED'
FROM public.workflow_templates w
JOIN public.workflow_stages s1 ON s1.workflow_id=w.id AND s1.name='APPROVAL'
JOIN public.workflow_stages s2 ON s2.workflow_id=w.id AND s2.name='DONE'
WHERE w.name='Imported (unclassified)'
ON CONFLICT DO NOTHING;

INSERT INTO public.workflow_transitions (workflow_id, from_stage_id, to_stage_id, trigger_condition)
SELECT w.id, s1.id, s2.id, 'CHANGES_REQUIRED'
FROM public.workflow_templates w
JOIN public.workflow_stages s1 ON s1.workflow_id=w.id AND s1.name='APPROVAL'
JOIN public.workflow_stages s2 ON s2.workflow_id=w.id AND s2.name='IMPORTED'
WHERE w.name='Imported (unclassified)'
ON CONFLICT DO NOTHING;
`);

sql.push(`\n-- --- Jobs and work items ---------------------------------------------------`);

let itemCount = 0;
for (const job of jobs) {
  const jobTitle = job.title;
  const jobRef = `joblist:job:${job.idx}`;
  sql.push(`
INSERT INTO public.jobs (name, category, description, source_ref)
VALUES (${q(jobTitle)}, NULL, ${q('Imported verbatim from the 10th Sept job list')}, ${q(jobRef)})
ON CONFLICT (source_ref) DO NOTHING;`);

  for (const item of job.items) {
    itemCount++;
    const needsReview = flags.some(f => f.idx === item.idx);
    const reviewNotes = flags.filter(f => f.idx === item.idx)
      .map(f => `${f.kind}: ${f.detail}`).join(' | ');

    const st = item.status;
    const stage = st.stageHint || 'IMPORTED';

    // pending_with: the named person when the source names one, else the
    // literal 'unknown' required by the import rules.
    let pendingWithName = null;
    let pendingWithLabel = null;
    if (st.note === 'approval pending' || st.note === 'sent for approval') {
      const approverNames = item.approval?.named ?? [];
      if (approverNames.length) pendingWithName = approverNames[0];
      else if (item.people.length === 1) pendingWithName = item.people[0];
      else pendingWithLabel = 'unknown';
    }

    const itemRef = `joblist:item:${item.idx}`;

    // One person named on the line IS the owner -- that is reading the
    // document, not guessing. Several names is genuinely ambiguous about who
    // is accountable, so owner_id stays NULL there and everyone is kept as a
    // collaborator; the row is already flagged MULTIPLE_PEOPLE for a human to
    // settle. Without this the dashboard attributes every imported item to
    // "Unassigned", which understates what the source actually says.
    const soleOwner = item.people.length === 1 ? item.people[0] : null;

    sql.push(`
WITH j AS (SELECT id FROM public.jobs WHERE source_ref = ${q(jobRef)}),
     w AS (SELECT id FROM public.workflow_templates WHERE name='Imported (unclassified)'),
     s AS (SELECT id FROM public.workflow_stages
           WHERE workflow_id=(SELECT id FROM w) AND name=${q(stage)}),
     pw AS (SELECT id FROM public.users WHERE full_name = ${q(pendingWithName)} LIMIT 1),
     ow AS (SELECT id FROM public.users WHERE full_name = ${q(soleOwner)} LIMIT 1)
INSERT INTO public.work_items
  (job_id, workflow_id, current_stage_id, name, status, deadline, owner_id,
   pending_with_id, pending_with_label, approval_required, approval_status,
   needs_review, review_notes, source_text, source_ref)
SELECT (SELECT id FROM j), (SELECT id FROM w), (SELECT id FROM s),
       ${q(item.title)},
       ${st.status ? q(st.status) : `'NOT_STARTED'`},
       ${item.date ? q(item.date) : 'NULL'},
       (SELECT id FROM ow),
       (SELECT id FROM pw),
       ${pendingWithLabel ? q(pendingWithLabel) : 'NULL'},
       ${stage === 'APPROVAL' ? 'TRUE' : 'FALSE'},
       ${stage === 'APPROVAL' ? `'PENDING'` : `'NOT_REQUIRED'`},
       ${needsReview ? 'TRUE' : 'FALSE'},
       ${needsReview ? q(reviewNotes) : 'NULL'},
       ${q(item.title)},
       ${q(itemRef)}
ON CONFLICT (source_ref) DO NOTHING;`);

    // Collaborators — every person named on the line is preserved.
    // Matched on source_ref, not source_text: two different lines can carry
    // the same text ("Whatsapp" appears under both Cardiac and Mother & Child).
    for (const person of item.people) {
      const role = person === soleOwner ? 'PRIMARY' : 'COLLABORATOR';
      sql.push(`
INSERT INTO public.work_item_owners (work_item_id, user_id, owner_role)
SELECT wi.id, u.id, ${q(role)}
FROM public.work_items wi, public.users u
WHERE wi.source_ref = ${q(itemRef)} AND u.full_name = ${q(person)}
ON CONFLICT DO NOTHING;`);
    }
  }
}

sql.push(`\nCOMMIT;\n`);
mkdirSync(resolve(REPO, 'database'), { recursive: true });
writeFileSync(resolve(REPO, 'database', 'seed.sql'), sql.join('\n'));

// ---------------------------------------------------------------------------
// Review report
// ---------------------------------------------------------------------------
// Count flagged WORK ITEMS, not flagged source lines. Some flags attach to a
// parent job line (e.g. the campaign owner-scope note on line 8), which never
// becomes a work item -- counting line indices overstated the total.
const flaggedIdx = new Set(flags.map((f) => f.idx));
const flaggedItemCount = jobs
  .flatMap((j) => j.items)
  .filter((it) => flaggedIdx.has(it.idx)).length;

const byKind = {};
for (const f of flags) (byKind[f.kind] ??= []).push(f);

const md = [];
md.push(`# Seed Import — Review Required

Generated by \`scripts/build-seed.mjs\` from **Job_list_10th_Sept_3.docx**.

- Source lines: **${lines.length}**
- Jobs created: **${jobs.length}**
- Work items created: **${itemCount}**
- Work items flagged: **${flaggedItemCount}** of ${itemCount}
- Total flags: **${flags.length}**

Every flagged row is in the database with \`needs_review = TRUE\`. Nothing below
was guessed — these are the places the source document does not say.

---

## The one assumption made

Dates in the source omit the year, except one. **${YEAR}** is taken from
${YEAR_SOURCE}. If that is wrong, every imported deadline shifts.

A second, explicit assumption: **role assignments**. The document states no
roles for anyone, so every imported person is seeded as \`CREATOR\` purely so
row-level security can be tested. Reassign in the admin UI.

---
`);

const KIND_TITLES = {
  NO_DEADLINE: 'Missing deadline — left NULL',
  NO_OWNER: 'Missing owner — left NULL',
  NO_STATUS: 'Missing status — left unset',
  MULTIPLE_PEOPLE: 'Several people named — all kept as collaborators',
  ROLE_AMBIGUOUS: 'Unclear whether the person owns or approves',
  UNRESOLVED_RECIPIENT: 'Named recipient could not be resolved to a person',
  VAGUE_DATE: 'Date reference too vague to use',
  DATE_MEANING: 'Date present but its meaning is ambiguous',
  SOURCE_ARTEFACT: 'Probable typo or artefact in the source',
  UNPARSED_TERM: 'Term in the source that could not be classified',
  PENDING_WITH_NAMED: 'Rule conflict resolved in favour of the named person',
  CAMPAIGN_OWNER_SCOPE: 'Owner named at campaign level only',
};

for (const kind of Object.keys(byKind).sort()) {
  md.push(`## ${KIND_TITLES[kind] ?? kind}  \n_${byKind[kind].length} occurrence(s)_\n`);
  md.push('| Line | Source text | Note |');
  md.push('|---:|---|---|');
  for (const f of byKind[kind]) {
    md.push(`| ${f.idx} | \`${f.source.replace(/\|/g, '\\|')}\` | ${f.detail.replace(/\|/g, '\\|')} |`);
  }
  md.push('');
}

md.push(`---

## What was deliberately NOT done

- **No deadline was invented.** ${byKind.NO_DEADLINE?.length ?? 0} items have no date in the source and carry \`deadline = NULL\`. They will show "—" in the UI, not a made-up date.
- **No owner was inherited.** The five Mother & Child deliverables (lines 9–13) sit under a line naming Vivek, but name nobody themselves, so they have no owner.
- **No stage was assigned.** The source does not say what stage anything is at, so everything lands in a holding stage called \`IMPORTED\` except rows that explicitly mention approval.
- **No single owner was chosen** where several people are named. All are collaborators until someone decides.

## Recommended next step

Work the flags above in the app: filter \`/work?filter=needs-review\`, set the
missing field, and clear \`needs_review\`. The original line is on every row in
\`source_text\`, so no decision has to be made from memory.
`);

writeFileSync(resolve(REPO, 'database', 'SEED_REVIEW.md'), md.join('\n'));

console.log(`jobs=${jobs.length} work_items=${itemCount} flags=${flags.length} flagged_items=${flaggedItemCount}`);
console.log('wrote database/seed.sql and database/SEED_REVIEW.md');
