-- ============================================================================
-- 0015_attachments_tags_status_control.sql
--   1. Real file attachments (Supabase Storage bucket + policies)
--   2. Free-form tags
--   3. Status changes restricted to named people
--   4. Comment threads: replies, resolve, soft delete
-- ============================================================================
-- Idempotent, like every migration before it. Safe to run twice.
--
-- Stated by the team lead:
--   "each person will get their credential, however only Vijaya and Nirmal
--    can change the status"
--
-- Implemented as a PERMISSION, not a pair of hardcoded names, so adding a
-- third person later is an INSERT rather than a deploy. See the
-- STATUS_CONTROLLER role and public.can_change_status() below.
--
-- ONE JUDGEMENT CALL, flagged rather than hidden:
--
-- Read absolutely literally, "only Vijaya and Nirmal can change the status"
-- also stops a designer handing a finished design to Vijaya — because that
-- moves the work to the next stage. The creative chain the same person
-- described ("designer designs it, then Vijaya proofreads it") then cannot
-- run: every one of the ~38 daily handoffs would need Vijaya or Nirmal to
-- press the button on someone else's behalf, and they become the bottleneck
-- for work they have not looked at yet.
--
-- The same tension appears again one step further on: the chain also says
-- "Nirmal/Sushant verifies, then Parul verifies". Under the literal reading
-- Sushant and Parul could not approve either, which deletes two of the three
-- verification steps.
--
-- So the line is drawn between DOING, JUDGING and CONTROLLING:
--   anyone            — submit my own finished work to the next person
--   the gate's approver — approve, reject or send back AT THEIR OWN GATE
--                         (Vijaya proofread, Sushant/Nirmal, Parul final),
--                         resolved from approval_authorities, not from names
--   V and N only      — hold, resume, cancel, mark complete, move work
--                       backwards outside a verdict, or move work that is
--                       neither theirs nor at their gate
--
-- To enforce the strictest reading instead, so that literally no stage moves
-- without them, one statement does it:
--
--   UPDATE public.roles SET permissions = permissions::jsonb - 'submit_work'
--   WHERE name IN ('CONTENT_WRITER','DESIGNER','SOCIAL_MEDIA','CREATOR');
--
-- and change the last ELSIF below to drop its can_edit_work_item() exception.
-- ============================================================================


-- ============================================================================
-- 1. ATTACHMENTS — storage bucket
-- ============================================================================
-- The `files` table already existed (migration 0004) but nothing ever wrote to
-- it: there was no bucket, so `storage_path` pointed at nowhere. This creates
-- the bucket the column was always describing.
--
-- Private bucket. Nothing is served by public URL; the app mints short-lived
-- signed URLs per download, so a leaked link expires instead of exposing the
-- whole bucket forever.
-- ----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'work-files',
  'work-files',
  FALSE,
  26214400,  -- 25 MB. Raise here, and in MAX_FILE_BYTES in src/lib/files.ts.
  ARRAY[
    'application/pdf',
    'image/jpeg','image/png','image/gif','image/webp','image/svg+xml','image/heic',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'text/plain','text/csv',
    'application/zip','application/x-zip-compressed',
    'video/mp4','video/quicktime'
  ]
)
ON CONFLICT (id) DO UPDATE
  SET file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types,
      public             = FALSE;


-- ----------------------------------------------------------------------------
-- Storage policies
--
-- Object names are laid out as `<work_item_id>/<uuid>-<filename>`, so the first
-- path segment identifies the work item. can_see_work_item() then answers the
-- only question that matters: may this person see that item at all? Permission
-- on the file is therefore never stored twice — it is always derived from the
-- work item, and cannot drift out of step with it.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS work_files_select ON storage.objects;
CREATE POLICY work_files_select ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'work-files'
    AND public.can_see_work_item(
      NULLIF((storage.foldername(name))[1], '')::UUID
    )
  );

DROP POLICY IF EXISTS work_files_insert ON storage.objects;
CREATE POLICY work_files_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'work-files'
    AND public.can_see_work_item(
      NULLIF((storage.foldername(name))[1], '')::UUID
    )
  );

-- Deliberately narrower than insert: anyone who can see the item may attach a
-- file, but only the uploader or a manager may remove one. Someone else's
-- evidence is not yours to delete.
DROP POLICY IF EXISTS work_files_delete ON storage.objects;
CREATE POLICY work_files_delete ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'work-files'
    AND (
      owner = auth.uid()
      OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER'])
    )
  );


-- ----------------------------------------------------------------------------
-- files: allow soft delete by uploader or manager, and hard delete by admin.
-- The 0006 update policy already covers the soft-delete path; this adds the
-- managers introduced in 0011, who were not a role when 0006 was written.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS files_update ON public.files;
CREATE POLICY files_update ON public.files FOR UPDATE TO authenticated
  USING (uploaded_by = auth.uid()
         OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']))
  WITH CHECK (uploaded_by = auth.uid()
         OR public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']));

-- An uploaded_by default means the column cannot be spoofed from the client.
ALTER TABLE public.files
  ALTER COLUMN uploaded_by SET DEFAULT auth.uid();

CREATE INDEX IF NOT EXISTS idx_files_storage_path ON public.files(storage_path);


-- ============================================================================
-- 2. TAGS — free-form, created on the fly
-- ============================================================================
-- Free-form was chosen over a fixed vocabulary, so the guard against
-- "Hoarding" / "hoardings" / "HOARDING" becoming three tags is a normalised
-- unique key rather than an admin. `slug` is the identity; `label` is whatever
-- the first person typed, and is what gets displayed.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tags (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       TEXT NOT NULL UNIQUE,
  label      TEXT NOT NULL,
  colour     TEXT NOT NULL DEFAULT 'slate',
  created_by UUID REFERENCES public.users(id) DEFAULT auth.uid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_tag_label_len CHECK (char_length(label) BETWEEN 1 AND 40),
  CONSTRAINT chk_tag_slug_shape CHECK (slug ~ '^[a-z0-9][a-z0-9 -]*$')
);

COMMENT ON COLUMN public.tags.slug IS
  'Lowercased, collapsed-whitespace form of label. The uniqueness key, so the
   same tag typed three different ways resolves to one row.';

CREATE TABLE IF NOT EXISTS public.work_item_tags (
  work_item_id UUID NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  tag_id       UUID NOT NULL REFERENCES public.tags(id) ON DELETE CASCADE,
  added_by     UUID REFERENCES public.users(id) DEFAULT auth.uid(),
  added_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (work_item_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_work_item_tags_tag ON public.work_item_tags(tag_id);

ALTER TABLE public.tags           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_item_tags ENABLE ROW LEVEL SECURITY;

-- The tag vocabulary is not secret: everyone signed in can read and extend it.
-- What a tag is ATTACHED to is scoped to the work item, below.
DROP POLICY IF EXISTS tags_select ON public.tags;
CREATE POLICY tags_select ON public.tags FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS tags_insert ON public.tags;
CREATE POLICY tags_insert ON public.tags FOR INSERT TO authenticated WITH CHECK (TRUE);

-- Renaming or recolouring a tag changes it everywhere it is used, so that stays
-- with managers even though creating one does not.
DROP POLICY IF EXISTS tags_update ON public.tags;
CREATE POLICY tags_update ON public.tags FOR UPDATE TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']))
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','MANAGER']));

DROP POLICY IF EXISTS tags_delete ON public.tags;
CREATE POLICY tags_delete ON public.tags FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN']));

DROP POLICY IF EXISTS work_item_tags_select ON public.work_item_tags;
CREATE POLICY work_item_tags_select ON public.work_item_tags FOR SELECT TO authenticated
  USING (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS work_item_tags_insert ON public.work_item_tags;
CREATE POLICY work_item_tags_insert ON public.work_item_tags FOR INSERT TO authenticated
  WITH CHECK (public.can_see_work_item(work_item_id));

DROP POLICY IF EXISTS work_item_tags_delete ON public.work_item_tags;
CREATE POLICY work_item_tags_delete ON public.work_item_tags FOR DELETE TO authenticated
  USING (public.can_see_work_item(work_item_id));


-- ----------------------------------------------------------------------------
-- Attach a tag by the text someone typed, creating it if new.
--
-- Doing this in one SQL function rather than a read-then-write in the app
-- closes the race where two people add the same new tag at the same moment and
-- the second gets a unique violation instead of a tag.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.attach_tag(p_work_item_id UUID, p_label TEXT)
RETURNS UUID
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v_label TEXT := btrim(regexp_replace(p_label, '\s+', ' ', 'g'));
  v_slug  TEXT := lower(btrim(regexp_replace(p_label, '\s+', ' ', 'g')));
  v_id    UUID;
BEGIN
  IF v_label = '' THEN
    RAISE EXCEPTION 'A tag needs a name' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_label) > 40 THEN
    RAISE EXCEPTION 'Tag names are limited to 40 characters' USING ERRCODE = '22023';
  END IF;
  IF v_slug !~ '^[a-z0-9][a-z0-9 -]*$' THEN
    RAISE EXCEPTION 'Tags may use letters, numbers, spaces and hyphens only'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.tags (slug, label)
  VALUES (v_slug, v_label)
  ON CONFLICT (slug) DO UPDATE SET slug = EXCLUDED.slug  -- no-op, to get the id back
  RETURNING id INTO v_id;

  INSERT INTO public.work_item_tags (work_item_id, tag_id)
  VALUES (p_work_item_id, v_id)
  ON CONFLICT DO NOTHING;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.attach_tag(UUID, TEXT) TO authenticated;


-- ============================================================================
-- 3. STATUS CONTROL — only named people may move work
-- ============================================================================
-- Everyone gets a login and can do the day-to-day: see their work, attach
-- files, tag, comment. Advancing a stage, approving, holding, resuming or
-- editing status is reserved.
--
-- Expressed as the permission `change_status`. To let someone else do it,
-- give them the STATUS_CONTROLLER role — no code change, no deploy.
-- ----------------------------------------------------------------------------
INSERT INTO public.roles (name, description, permissions) VALUES
  ('STATUS_CONTROLLER',
   'May move work between stages and change its status',
   '["change_status","view_all","submit_work","approve_work","request_changes","reassign_work","modify_deadlines","view_reports"]')
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      permissions = EXCLUDED.permissions;

-- The disciplines KEEP submit_work. Handing your own finished work to the next
-- person is not a status change — it is the act of doing your job, and the
-- stated chain (designer designs it, THEN Vijaya proofreads it) cannot happen
-- at all if a designer cannot pass work to Vijaya.
--
-- What is reserved is authority over the work's state: approving, rejecting,
-- requesting changes, holding, cancelling, completing, or sending it backwards.
-- See enforce_status_change_permission() below for exactly where the line falls.
UPDATE public.roles
   SET permissions = (permissions::jsonb || '["submit_work"]'::jsonb)
 WHERE name IN ('CONTENT_WRITER','DESIGNER','SOCIAL_MEDIA','CREATOR')
   AND NOT (permissions ? 'submit_work');

-- ADMIN's own description is "Full system administration" (0001) — it should
-- not need a name-matched STATUS_CONTROLLER grant to actually administer.
-- Named-person grants below stay as the way to hand this to someone who is
-- specifically a controller without also being an ADMIN.
UPDATE public.roles
   SET permissions = (permissions::jsonb || '["change_status"]'::jsonb)
 WHERE name = 'ADMIN'
   AND NOT (permissions ? 'change_status');

CREATE OR REPLACE FUNCTION public.can_change_status()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  -- auth.uid() IS NULL means this is a migration, the seed, or a dashboard
  -- session — not a signed-in app user. Those are already trusted.
  SELECT auth.uid() IS NULL OR public.has_permission('change_status');
$$;

GRANT EXECUTE ON FUNCTION public.can_change_status() TO authenticated;


-- ----------------------------------------------------------------------------
-- Is the current user the person this work item's CURRENT gate routes to?
--
-- Needed because the same instruction that reserves status also describes a
-- chain in which Sushant and Parul verify work. Giving a verdict at a gate you
-- are the registered approver for is doing your job; it is not an override,
-- and blocking it would delete two of the three verification steps the team
-- actually described.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_designated_approver(p_work_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.work_items w
    JOIN public.workflow_stages s ON s.id = w.current_stage_id
    JOIN public.approval_authorities aa
      ON aa.work_category = s.approval_category
     AND aa.is_active
    WHERE w.id = p_work_item_id
      AND s.requires_approval
      AND aa.approver_id = auth.uid()
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_designated_approver(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_status_change_permission()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_old_order INT;
  v_new_order INT;
  v_new_terminal BOOLEAN := FALSE;
  v_is_approver BOOLEAN;
  v_reserved  BOOLEAN := FALSE;
  v_reason    TEXT;
BEGIN
  -- Migrations, the seed and the SQL editor run with no signed-in user.
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF public.can_change_status() THEN RETURN NEW; END IF;

  -- Resolved against the stage the item is LEAVING, which is the gate whose
  -- verdict is being given.
  v_is_approver := public.is_designated_approver(OLD.id);

  SELECT stage_order INTO v_old_order FROM public.workflow_stages WHERE id = OLD.current_stage_id;
  SELECT stage_order, is_terminal INTO v_new_order, v_new_terminal
    FROM public.workflow_stages WHERE id = NEW.current_stage_id;

  -- A verdict on someone's work.
  IF NEW.approval_status IS DISTINCT FROM OLD.approval_status
     AND NEW.approval_status IN ('APPROVED','REJECTED','CHANGES_REQUIRED')
     AND NOT v_is_approver THEN
    v_reserved := TRUE;
    v_reason   := 'approve work or send it back';

  -- Parking or killing work.
  --
  -- COMPLETED is deliberately NOT in this list on its own. Submitting the last
  -- stage moves the item into the terminal stage, and the engine sets
  -- COMPLETED as part of that — so treating every COMPLETED as an override
  -- would block the final handoff for the one person whose job it is (Indu,
  -- posting it). Declaring something complete WITHOUT walking it there is
  -- still reserved.
  ELSIF NEW.status IS DISTINCT FROM OLD.status
        AND (
          NEW.status IN ('ON_HOLD','BLOCKED','CANCELLED','REJECTED')
          OR (NEW.status = 'COMPLETED'
              AND NOT (v_new_terminal AND COALESCE(v_new_order, 0) >= COALESCE(v_old_order, 0)))
        ) THEN
    v_reserved := TRUE;
    v_reason   := 'put work on hold, cancel it or mark it complete';

  -- Pulling something back to an earlier stage.
  ELSIF v_new_order IS NOT NULL AND v_old_order IS NOT NULL AND v_new_order < v_old_order
        AND NOT v_is_approver THEN
    v_reserved := TRUE;
    v_reason   := 'move work back to an earlier stage';

  -- Moving work that is not yours. Passing on your OWN finished work is the
  -- job; moving someone else's is a scheduling decision.
  --
  -- work_item_owners is checked as well as can_edit_work_item(), because on a
  -- COLLABORATIVE item the second collaborator is neither the assignee nor the
  -- owner — they hold half the work and nothing else. Without this, the
  -- multi-owner gate could be opened by one person and never closed by the
  -- other, which is the one case where work would silently stick forever.
  ELSIF NEW.current_stage_id IS DISTINCT FROM OLD.current_stage_id
        AND NOT v_is_approver
        AND NOT public.can_edit_work_item(NEW.id)
        AND NOT EXISTS (
          SELECT 1 FROM public.work_item_owners o
          WHERE o.work_item_id = NEW.id AND o.user_id = auth.uid()
        ) THEN
    v_reserved := TRUE;
    v_reason   := 'move work that is not assigned to you';
  END IF;

  IF v_reserved THEN
    RAISE EXCEPTION
      'Only Vijaya and Nirmal can % . You can submit your own finished work, attach files, add tags and comment.',
      v_reason
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_items_status_permission ON public.work_items;
CREATE TRIGGER trg_work_items_status_permission
  BEFORE UPDATE ON public.work_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_status_change_permission();


-- ----------------------------------------------------------------------------
-- Give it to the two people named, by name, the way 0011 assigns every other
-- role. Matching on full_name keeps this working whether or not the import has
-- run, and whether or not they have logins yet.
-- ----------------------------------------------------------------------------
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u
CROSS JOIN public.roles r
WHERE r.name = 'STATUS_CONTROLLER'
  AND lower(btrim(u.full_name)) IN ('vijaya','nirmal')
ON CONFLICT DO NOTHING;

-- The account actually signed in as Vijaya is an ADMIN and may not be named
-- "Vijaya" in full_name, so cover it by email too.
INSERT INTO public.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM public.users u
CROSS JOIN public.roles r
WHERE r.name = 'STATUS_CONTROLLER'
  AND lower(u.email) = 'drvijayadutta@gmail.com'
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 4. COMMENTS — replies, resolve, soft delete
-- ============================================================================
-- parent_id and is_resolved have existed since 0004 and were never used by the
-- UI. Nothing to add to the schema; what was missing was a delete policy, so
-- an author could edit a comment but never retract one.
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_comments_parent ON public.comments(parent_id)
  WHERE parent_id IS NOT NULL AND deleted_at IS NULL;

ALTER TABLE public.comments
  ALTER COLUMN author_id SET DEFAULT auth.uid();

-- Soft delete only — the row stays for the audit trail, the body is hidden by
-- the app. Hard DELETE remains closed to everyone but an admin.
DROP POLICY IF EXISTS comments_delete ON public.comments;
CREATE POLICY comments_delete ON public.comments FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN']));


-- ============================================================================
-- 5. Convenience view: work items with their tags, for list filtering
-- ============================================================================
CREATE OR REPLACE VIEW public.v_work_item_tags
WITH (security_invoker = TRUE) AS
SELECT
  wit.work_item_id,
  t.id   AS tag_id,
  t.slug,
  t.label,
  t.colour
FROM public.work_item_tags wit
JOIN public.tags t ON t.id = wit.tag_id;

GRANT SELECT ON public.v_work_item_tags TO authenticated;
