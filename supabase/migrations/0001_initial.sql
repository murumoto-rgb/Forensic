-- 0001_initial.sql — Phase 1, migration 1.
--
-- Establishes the bare-minimum tables for the server to work:
--   * `profiles` — extends Supabase's built-in auth.users with
--     app-level fields (display name, cached email, timestamps).
--   * `projects` — one row per Forensic project, with the iOS
--     `Project` Codable struct stored verbatim in a `jsonb`
--     `manifest` column. Top-level name + owner are also stored
--     as plain columns so the project-list query doesn't have to
--     crack the blob open.
--
-- Phase 1 deliberately keeps it small. Audit log and multi-user
-- access tables land in later migrations once the server can
-- actually create and read a project.
--
-- Run by pasting this whole file into Supabase Dashboard →
-- SQL Editor → New query → Run.

-- ============================================================
-- Generic updated-at trigger (used by every table with an
-- `updated_at` column).
-- ============================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================
-- profiles
-- ============================================================
-- Mirrors auth.users 1-to-1. We never reference auth.users
-- directly from app code; everything goes through this table.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Automatically create a profile row when a user signs up via
-- Supabase Auth. Runs as `security definer` so it can insert
-- into public.profiles regardless of the calling role.
-- `search_path = ''` per Supabase's security guidance — prevents
-- schema-injection attacks against this function.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- RLS policies for profiles.
-- The automatic-RLS setting we enabled at project create time
-- already turned RLS on for this table; without policies, nothing
-- can read or write. These policies grant:
--   * SELECT own row (so the client can show "Welcome, NAME" via
--     the publishable key).
--   * UPDATE own row (so users can rename themselves).
-- INSERT happens via the handle_new_user trigger above (security
-- definer bypasses RLS). DELETE cascades from auth.users.

create policy "Users can read own profile"
  on public.profiles for select
  using (auth.uid() = id);

create policy "Users can update own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- ============================================================
-- projects
-- ============================================================
-- One row per Forensic project. `id` matches the iOS-side
-- `Project.id` UUID — clients send their existing UUID on upload,
-- and the server uses it as the primary key. `manifest` is the
-- full Project struct encoded as JSON by the iOS JSONEncoder,
-- mirroring `packages/shared/src/manifest.ts`.
--
-- `revision` is an opaque token bumped on every write. Clients
-- send their last-known revision on PUT; the server rejects
-- mismatches with 409. This gives optimistic concurrency without
-- explicit locks during Phases 1–4 (the lock model lands in
-- Phase 5).
--
-- `manifest_schema_version` is duplicated from inside the JSON
-- blob to a top-level column so the server can route / reject
-- based on it without parsing the whole JSON. Server-side
-- validation enforces that the two values agree on every write.

create table public.projects (
  id                       uuid        primary key,
  owner_id                 uuid        not null references auth.users (id) on delete cascade,
  name                     text        not null,
  manifest                 jsonb       not null,
  manifest_schema_version  int         not null,
  revision                 text        not null default gen_random_uuid()::text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create index projects_owner_id_idx on public.projects (owner_id);

create trigger projects_set_updated_at
  before update on public.projects
  for each row execute function public.set_updated_at();

-- RLS policies for projects.
-- All writes go through the Fastify server using the secret key
-- (which bypasses RLS). The SELECT policy here is defense-in-depth
-- so that if a publishable-key client ever reads this table
-- directly, it can only see its own projects. Phase 5 (multi-user
-- collaboration) extends this with a project_access join table
-- and a corresponding policy.

create policy "Owners can read own projects"
  on public.projects for select
  using (auth.uid() = owner_id);
