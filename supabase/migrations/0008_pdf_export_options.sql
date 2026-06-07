-- 0008_pdf_export_options.sql — Phase 4, migration 8.
--
-- Per-job options for the server-side PDF export (Build #5.64.1,
-- PR #3 of 3 for plan item #3). The skeleton PR (#5.62.1) treated
-- every export identically; the layout PR (#5.63.1) added a fixed
-- multi-page report. This PR lets the user pick page size,
-- photos-per-page, photo filter, and what sections to include.
--
-- We store the options as JSONB so the schema can evolve without
-- another migration when a future PR adds a new option (e.g.
-- "include AI rules summary," "include bucket index"). The shape
-- the server writes / reads is enforced by the `PdfExportOptions`
-- TypeScript + zod schema in the application layer, not by SQL.

alter table public.pdf_export_jobs
  add column if not exists options jsonb;

-- Index isn't useful — every job has a row, the options aren't
-- queried by content. We omit the GIN index that would be the
-- normal default for a JSONB column.
