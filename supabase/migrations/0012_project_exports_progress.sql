-- 0012_project_exports_progress.sql — migration 12.
--
-- Per-job progress tracking for the folder + CSV export workers
-- (Build #5.106.1). Mirrors the chunked-render progress columns
-- migration 0009 added to `pdf_export_jobs`.
--
-- Both columns are nullable so jobs that completed before this PR
-- (or jobs that fail before the first progress update) still read
-- back cleanly without a 0/0 placeholder.

alter table public.project_exports
  add column if not exists progress_done int,
  add column if not exists progress_total int;
