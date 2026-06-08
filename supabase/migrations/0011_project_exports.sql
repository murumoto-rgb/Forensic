-- 0011_project_exports.sql — migration 11.
--
-- Unified persistence layer for every export the user generates
-- against a project: PDF reports, Folder-by-Bucket bundles, and AI
-- Analysis CSV (Build #5.97.1).
--
-- Replaces the per-kind table approach (the existing
-- `pdf_export_jobs` queue stays in place for in-flight PDF jobs;
-- this new table is the durable record of every COMPLETED export,
-- plus the queue + result for the two new export kinds added in
-- this PR — folder bundles and CSVs).
--
-- Model:
--   * id           — UUID PK exposed as the export handle.
--   * project_id   — the project being exported.
--   * created_by   — Supabase user id; used for ownership filtering.
--   * kind         — 'pdf' | 'folder' | 'csv'.
--   * status       — 'queued' | 'running' | 'done' | 'failed'.
--   * object_key   — R2 key once done. NULL otherwise.
--   * size_bytes   — bytes of the rendered artifact for the listing UI.
--   * options      — jsonb; per-kind options struct (mirrors iOS's
--                    FolderExportRunner toggles, the PDF options
--                    sheet, etc.). Worker validates per-kind.
--   * error_message— populated on failed.
--   * Timestamps for created / started / completed.
--
-- RLS: every signed-in user reads their own rows. Writes go through
-- the Fastify service role (bypasses RLS), gated by app-layer
-- ownership checks.

create table public.project_exports (
  id               uuid primary key default gen_random_uuid(),
  project_id       uuid not null references public.projects (id) on delete cascade,
  created_by       uuid not null references auth.users (id) on delete cascade,
  kind             text not null check (kind in ('pdf', 'folder', 'csv')),
  status           text not null check (status in ('queued', 'running', 'done', 'failed')),
  object_key       text,
  size_bytes       bigint,
  options          jsonb not null default '{}'::jsonb,
  error_message    text,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  completed_at     timestamptz
);

-- Worker scans here every few seconds; an index keeps the queue
-- probe cheap even as completed export history grows.
create index project_exports_status_idx
  on public.project_exports (status, kind, created_at)
  where status in ('queued', 'running');

-- The exports-page listing UI fetches by project, newest first.
create index project_exports_project_created_idx
  on public.project_exports (project_id, created_at desc);

alter table public.project_exports enable row level security;

create policy "Users read their own exports"
  on public.project_exports for select
  to authenticated
  using (auth.uid() = created_by);
