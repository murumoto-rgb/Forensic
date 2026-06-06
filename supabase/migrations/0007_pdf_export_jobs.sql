-- 0007_pdf_export_jobs.sql — Phase 4, migration 7.
--
-- Server-side PDF export queue (Build #5.62.1, plan item #3).
--
-- The web "Export PDF" button enqueues a job; a background worker
-- inside the server process picks it up, renders the manifest into
-- an HTML page, prints it to a PDF via headless Chromium, uploads
-- the result to R2, and marks the job done. The web client polls
-- this table (via the GET endpoint) for status, and downloads from
-- R2 via a short-lived presigned URL once the PDF is ready.
--
-- The iOS PDF export remains the authoritative one for client
-- deliverables; this server-side path is an "office preview" so
-- staff can read the report in a browser without an iPad.
--
-- Model:
--   * `id` UUID PK — surfaced to the web client as the job handle.
--   * `project_id` — the project being exported.
--   * `requested_by` — Supabase user id; used for ownership checks
--     on GET so a stray jobId doesn't leak someone else's PDF.
--   * `status`: 'queued' | 'running' | 'done' | 'failed'. Worker
--     transitions queued → running atomically (claim) and
--     running → done|failed when the render finishes.
--   * `pdf_object_key`: R2 key once done. NULL otherwise.
--   * `error_message`: populated on failed.
--   * Timestamps for created / started / completed support both
--     ops triage and a future "average render time" stat.
--
-- Cleanup: this PR doesn't delete old rows. A future migration may
-- add a TTL (e.g. delete done/failed rows older than 30 days) when
-- the volume justifies it.

create table public.pdf_export_jobs (
  id              uuid primary key default gen_random_uuid(),
  project_id      uuid not null references public.projects (id) on delete cascade,
  requested_by    uuid not null references auth.users (id) on delete cascade,
  status          text not null check (status in ('queued', 'running', 'done', 'failed')),
  pdf_object_key  text,
  error_message   text,
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  completed_at    timestamptz
);

-- Worker scans here every few seconds; an index on the status column
-- keeps the queue probe cheap as job history grows.
create index pdf_export_jobs_status_idx
  on public.pdf_export_jobs (status, created_at)
  where status in ('queued', 'running');

-- Show me my jobs (for the "recent exports" view, future PR).
create index pdf_export_jobs_requested_by_idx
  on public.pdf_export_jobs (requested_by, created_at desc);

alter table public.pdf_export_jobs enable row level security;

-- RLS read policy: a user can read their own jobs only. Writes go
-- through the server's secret key (worker claims + status updates).
create policy "Users can read their own export jobs"
  on public.pdf_export_jobs for select
  using (auth.uid() = requested_by);
