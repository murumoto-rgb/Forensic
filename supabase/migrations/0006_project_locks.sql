-- 0006_project_locks.sql — Phase 2 (belated), migration 6.
--
-- Collaboration lock: at most one editor holds the edit lock for a
-- project at a time; everyone else views read-only. The lock
-- auto-expires after a heartbeat window so a closed browser / crashed
-- app doesn't strand the project forever (Build #5.59.1).
--
-- Model:
--   * `project_id` is the PK — one lock row per project, at most.
--   * `user_id` is the holder. `acquired_at` / `last_heartbeat` /
--     `expires_at` drive expiry. The editing client heartbeats every
--     ~90s, bumping `last_heartbeat` + `expires_at = now() + 10 min`.
--   * `client` records 'web' | 'ios' for display ("Editing on web").
--
-- Server logic (in `server/src/routes/locks.ts`):
--   * Acquire is an UPSERT guarded by an expiry check — you can take
--     the lock if it's free OR the existing one has expired. A live
--     lock held by another user returns 409.
--   * Heartbeat bumps the window; rejects if you're not the holder.
--   * Release deletes the row (only the holder, or an admin force).
--
-- Expiry is enforced in application logic (the acquire query treats
-- `expires_at < now()` as free) rather than a background job — no
-- cron needed, and a stale row is harmless until someone tries to
-- acquire.

create table public.project_locks (
  project_id      uuid        primary key references public.projects (id) on delete cascade,
  user_id         uuid        not null references auth.users (id) on delete cascade,
  user_email      text        not null,
  client          text        not null check (client in ('web', 'ios')),
  acquired_at     timestamptz not null default now(),
  last_heartbeat  timestamptz not null default now(),
  expires_at      timestamptz not null
);

create index project_locks_expires_at_idx on public.project_locks (expires_at);

alter table public.project_locks enable row level security;

-- RLS read policy: any signed-in user can SEE who holds a lock (so a
-- read-only viewer's banner can name the editor). All writes go
-- through the server's secret key, which bypasses RLS — the acquire /
-- heartbeat / release endpoints enforce holder rules in app logic.
create policy "Signed-in users can read project locks"
  on public.project_locks for select
  using (auth.uid() is not null);
