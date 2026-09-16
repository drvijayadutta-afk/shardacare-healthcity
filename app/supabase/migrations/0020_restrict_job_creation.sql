-- ============================================================================
-- 0020_restrict_job_creation.sql — only an ADMIN may start new work
-- ============================================================================
-- Creating work was open to ADMIN, WORKFLOW_MANAGER and COORDINATOR (0006).
-- It is now ADMIN only. Everyone else keeps everything else: a workflow
-- manager still sees the Control Tower, still reassigns, still approves — they
-- simply cannot open a new job.
--
-- Two policies have to move, not one.
--
-- work_items_insert was the obvious half: a straight role list.
--
-- jobs_write was the half that would have been missed. It is FOR ALL with
--
--   WITH CHECK (has_role(...) OR created_by = auth.uid() OR requester_id = auth.uid())
--
-- and on an INSERT only WITH CHECK is evaluated — so that second branch let
-- ANY authenticated user insert a job simply by putting their own id in
-- created_by. Narrowing the role list alone would have left that path wide
-- open and made this migration a lie. The INSERT case is therefore split out
-- of the FOR ALL policy and given its own ADMIN-only rule; UPDATE and DELETE
-- keep the original behaviour, so a requester can still edit the job they are
-- attached to.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- work_items: only an ADMIN may create one
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS work_items_insert ON public.work_items;
CREATE POLICY work_items_insert ON public.work_items FOR INSERT TO authenticated
  WITH CHECK (public.has_role(ARRAY['ADMIN']));

-- ----------------------------------------------------------------------------
-- jobs: INSERT split away from UPDATE/DELETE
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS jobs_write ON public.jobs;

DROP POLICY IF EXISTS jobs_insert ON public.jobs;
CREATE POLICY jobs_insert ON public.jobs FOR INSERT TO authenticated
  WITH CHECK (public.has_role(ARRAY['ADMIN']));

-- Unchanged from the old jobs_write, minus the INSERT case: whoever the job
-- belongs to can still maintain it.
DROP POLICY IF EXISTS jobs_modify ON public.jobs;
CREATE POLICY jobs_modify ON public.jobs FOR UPDATE TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid())
  WITH CHECK (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid());

DROP POLICY IF EXISTS jobs_delete ON public.jobs;
CREATE POLICY jobs_delete ON public.jobs FOR DELETE TO authenticated
  USING (public.has_role(ARRAY['ADMIN','WORKFLOW_MANAGER','COORDINATOR'])
         OR created_by = auth.uid() OR requester_id = auth.uid());
