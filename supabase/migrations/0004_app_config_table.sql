-- 0004_app_config_table.sql — Phase 4, migration 4.
--
-- App-wide configuration mirrors. The five pieces of state iOS keeps
-- on `ProjectStore` (tag library, AI rules template, bucket library,
-- report branding, AI prompt templates) need to be reachable by the
-- web client and any future server-side prompt assembly so that the
-- web "Re-tag with AI" button, the server-side PDF renderer, and the
-- planned admin pages all see the same vocabulary / rules / branding
-- the engineer customised on iOS.
--
-- Schema is intentionally generic — one row per (key, value) pair —
-- so adding a sixth piece of config later (or a per-user override
-- variant) doesn't require a new migration. The per-key shape is
-- enforced by zod schemas on the server's PUT route, NOT by SQL
-- constraints, which would just be a second duplicate place to keep
-- in sync.
--
-- Concurrency: each row carries an opaque `revision` string the
-- client echoes back on PUT — same optimistic-concurrency shape the
-- `projects` table uses (Phase 1) — so a stale write loses with a
-- 409 rather than silently overwriting fresher edits the other
-- platform may have made.
--
-- Owner: rows are intentionally NOT scoped per user. The team's iOS
-- engineer is the editor; everyone else reads the same vocabulary.
-- Phase 5 may add a per-team owner column once multi-team support
-- lands; the current single-team model doesn't need it.

create table public.app_config (
  key         text        primary key,
  value       jsonb       not null,
  revision    text        not null default gen_random_uuid()::text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid        references auth.users (id) on delete set null
);

create trigger app_config_set_updated_at
  before update on public.app_config
  for each row execute function public.set_updated_at();

-- RLS defense-in-depth. All writes flow through the Fastify server
-- using the secret key (bypasses RLS). The read policy below grants
-- any signed-in user SELECT on every row — the tag library + AI
-- rules + branding + bucket library + prompt templates are team-
-- wide, not per-user, so cross-user visibility is the intended
-- behaviour.

alter table public.app_config enable row level security;

create policy "Signed-in users can read app config"
  on public.app_config for select
  using (auth.uid() is not null);
