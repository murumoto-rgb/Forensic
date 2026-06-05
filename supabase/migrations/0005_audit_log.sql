-- 0005_audit_log.sql — Phase 4, migration 5.
--
-- Append-only audit log for AI tagging calls (Build #5.45.1). The
-- server's `/v1/ai/tag-photo` proxy writes one row per Anthropic
-- call carrying enough metadata to answer "who tagged what with
-- which model, when, and what did it cost?"
--
-- The row is best-effort — a write failure here does NOT fail the
-- caller's request (the proxy logs and continues). Useful for cost
-- forecasting + per-user attribution; not relied on for correctness.
--
-- `cost_estimate_cents` is computed server-side from Anthropic's
-- per-model rates at call time. Recorded as an integer count of
-- 0.01 cents (i.e. hundred-thousandths of a USD) so a single
-- low-cost call still has non-zero precision. Sample: a Sonnet 4.6
-- call with 5,000 input tokens + 800 output tokens = 5000 * $3 +
-- 800 * $15 per 1M = $0.027 = 270 hundred-thousandths of USD =
-- 2700 hundred-thousandths-of-a-cent. The cents column is sized
-- bigint so even a year of busy team usage fits comfortably.
--
-- No DELETE policy — append-only by design. If a row needs to be
-- purged for compliance reasons, the manual SQL path remains
-- available to the database owner.

create table public.audit_log (
  id                              bigserial   primary key,
  event_type                      text        not null,
  user_id                         uuid        references auth.users (id) on delete set null,
  project_id                      uuid        references public.projects (id) on delete set null,
  photo_id                        uuid,
  model                           text,
  input_tokens                    int,
  output_tokens                   int,
  cache_read_tokens               int,
  cache_creation_tokens           int,
  duration_ms                     int,
  -- Hundred-thousandths of a USD cent (i.e. units of 1e-5 cents)
  -- so a single low-cost call still has non-zero precision.
  -- Divide by 100,000 to get cents; divide by 10,000,000 for USD.
  cost_estimate_hundred_thousandths_of_cents bigint,
  detail                          jsonb,
  created_at                      timestamptz not null default now()
);

create index audit_log_created_at_idx on public.audit_log (created_at desc);
create index audit_log_user_id_idx on public.audit_log (user_id);
create index audit_log_project_id_idx on public.audit_log (project_id);
create index audit_log_event_type_idx on public.audit_log (event_type);

alter table public.audit_log enable row level security;

-- Read policy: signed-in users can see their own audit rows. Admin
-- aggregation queries go through the server's secret key (bypasses
-- RLS) so this policy doesn't block per-team cost dashboards
-- shipped later.
create policy "Users can read own audit rows"
  on public.audit_log for select
  using (auth.uid() = user_id);
