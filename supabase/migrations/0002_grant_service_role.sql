-- 0002_grant_service_role.sql — Phase 1, migration 2.
--
-- When the project was created with "Automatically expose new tables"
-- disabled (the recommended security setting), new tables created by
-- raw SQL receive no GRANTs to the standard Supabase roles —
-- including `service_role`, which is what our server uses.
-- The first attempt to read `public.projects` from the server failed
-- with Postgres error 42501 "permission denied for table projects".
--
-- This migration grants the privileges each role needs.

-- The server uses the secret key (service_role role) for every DB
-- operation. It bypasses RLS but still needs table-level GRANTs.
grant select, insert, update, delete on table public.profiles to service_role;
grant select, insert, update, delete on table public.projects to service_role;

-- The publishable key resolves to the `authenticated` role for
-- signed-in users. The RLS policies from 0001_initial.sql already
-- limit reads to own-row / own-project rows; without these GRANTs,
-- the policies are unreachable (the role can't even see the table).
-- Clients don't currently read these tables directly (everything
-- goes through the server), but defense-in-depth is cheap.
grant select, update on table public.profiles to authenticated;
grant select on table public.projects to authenticated;

-- Make future migrations less error-prone: from now on, any new
-- table in the public schema auto-grants the right privileges to
-- service_role + authenticated. (Anon stays out by default.)
alter default privileges in schema public
  grant all on tables to service_role;
alter default privileges in schema public
  grant select on tables to authenticated;
