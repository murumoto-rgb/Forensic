-- 0014_collaboration_roles.sql — Phase 3 of the cloud-first program,
-- Build #5.121.1.
--
-- Adds the data model for multi-user collaboration:
--   * Org-level Admin flag on `profiles` (boolean column).
--   * Per-project Editor / Viewer membership via a new
--     `project_members` join table.
--
-- Effective-role resolution order (computed in
-- `server/src/access.ts` in a later PR — this migration is
-- additive-only and lands first):
--
--     admin  >  owner (implicit editor)  >  member.role  >  none
--
-- The owner stays a single column on `projects`; owners are an
-- implicit Editor on their project and are NEVER duplicated into
-- `project_members`. Folding owner into the join table would have
-- required a data migration of every existing row plus a
-- "who can delete the project" concept that owner already encodes.
--
-- This migration is **additive only**. Existing queries
-- (`.eq("owner_id", request.user.id)`) keep working unchanged
-- because owners still match the existing single-owner path.
-- The per-route refactor that consumes membership lands in the
-- next PR.

-- ============================================================
-- 1) Org Admin flag on profiles.
-- ============================================================
-- Bool, default false. Set true on a per-email basis via the
-- bootstrap migration 0015 (and later via the admin API).

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

-- ============================================================
-- 2) project_members — per-project Editor/Viewer membership.
-- ============================================================
-- PK is (project_id, user_id) so a user has at most one role per
-- project. `role` is text + CHECK to match the codebase's
-- existing convention (files.kind, project_exports.kind in
-- migrations 0003 / 0011 use the same pattern — not a native
-- Postgres enum).
--
-- `added_by` records the admin/owner who granted access; `set
-- null` on user delete so we don't lose the row when the granting
-- admin is removed. `cascade` on project / user delete because
-- a membership without its project or user is meaningless.

create table public.project_members (
  project_id  uuid        not null references public.projects (id) on delete cascade,
  user_id     uuid        not null references auth.users     (id) on delete cascade,
  role        text        not null check (role in ('editor','viewer')),
  added_by    uuid        references auth.users (id) on delete set null,
  added_at    timestamptz not null default now(),
  primary key (project_id, user_id)
);

-- "List projects I'm a member of" (powers the unioned project
-- list query in the upcoming server refactor).
create index project_members_user_id_idx
  on public.project_members (user_id);

-- "List the members of this project" (powers the per-project
-- assignment editor on the project Info tab).
create index project_members_project_id_idx
  on public.project_members (project_id);

alter table public.project_members enable row level security;

-- ============================================================
-- 3) Defense-in-depth RLS.
-- ============================================================
-- All real authorization lives in the server's `access.ts`
-- helper (the server uses the service-role key and bypasses
-- RLS). These policies exist so a publishable-key reader (if
-- one is ever wired up directly to a member project) can read
-- only what it should.

-- A signed-in user can read THEIR OWN membership rows. Narrow
-- on purpose: avoids any policy cycle between project_members
-- and projects (the projects policy below references members,
-- but members doesn't reference projects in its own policy).
create policy "Members can read own membership"
  on public.project_members for select
  using (auth.uid() = user_id);

-- Widen the `projects` SELECT visibility so a member (or org
-- admin) can read project rows that aren't owned by them. The
-- existing owner-only policy from 0001 stays — this is an
-- additional permissive policy that ORs in.
create policy "Members can read member projects"
  on public.projects for select
  using (
    exists (
      select 1
      from public.project_members m
      where m.project_id = projects.id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.is_admin
    )
  );

-- Same widening on `files`: members and admins can read files
-- for member projects. The existing owner-scoped policy from
-- 0003 keeps working unchanged.
create policy "Members can read files for member projects"
  on public.files for select
  using (
    exists (
      select 1
      from public.projects p
      where p.id = files.project_id
        and (
          p.owner_id = auth.uid()
          or exists (
            select 1
            from public.project_members m
            where m.project_id = p.id
              and m.user_id = auth.uid()
          )
          or exists (
            select 1
            from public.profiles pr
            where pr.id = auth.uid()
              and pr.is_admin
          )
        )
    )
  );
