-- 0010_user_prefs.sql — migration 10.
--
-- Per-user UI preferences (Build #5.95.1). Three knobs the settings
-- page (and the batch-retag control) read on every render:
--   * AI model preference (sonnet vs haiku).
--   * Tag confidence threshold.
--   * Parallel AI request concurrency.
--
-- One row per user, identified by their auth.users(id). Stored as
-- a flat JSON blob so adding new pref fields later doesn't require
-- another migration — the per-field shape is enforced by zod on the
-- server's PUT route, same approach app_config uses.
--
-- Concurrency: each row carries an opaque `revision` string the
-- client echoes back on PUT — mirrors the app_config + projects
-- pattern so a stale write loses with 409.

create table public.user_prefs (
  user_id     uuid        primary key references auth.users (id) on delete cascade,
  prefs       jsonb       not null default '{}'::jsonb,
  revision    text        not null default gen_random_uuid()::text,
  updated_at  timestamptz not null default now()
);

create trigger user_prefs_set_updated_at
  before update on public.user_prefs
  for each row execute function public.set_updated_at();

-- RLS defense-in-depth. All writes flow through the Fastify server
-- using the secret key. Read policy lets a signed-in user see their
-- own row only.
alter table public.user_prefs enable row level security;

create policy "Users can read their own prefs"
  on public.user_prefs for select
  to authenticated
  using (auth.uid() = user_id);
