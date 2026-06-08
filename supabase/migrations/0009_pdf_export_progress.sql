-- 0009_pdf_export_progress.sql — migration 9.
--
-- Per-chunk progress tracking for the PDF export worker
-- (Build #5.75.1). The chunked-rendering pipeline added in #5.72.1
-- splits an export into N HTML chunks; the worker now updates these
-- two columns after each chunk so the web client can show a
-- meaningful "Rendering chunk 4 of 9 (44%)" indicator instead of
-- the binary "Rendering…" it had before.
--
-- Both columns are nullable so jobs persisted before this PR (and
-- jobs that fail before the first chunk update) can still be read
-- back without coercing a 0/0 placeholder.

alter table public.pdf_export_jobs
  add column if not exists progress_done_chunks int,
  add column if not exists progress_total_chunks int;
