-- 0015_seed_first_admin.sql — Phase 3 first-admin bootstrap,
-- Build #5.121.1.
--
-- There is no admin yet. This migration flips the org-admin flag
-- on the single known user. It is:
--
--   * Idempotent — re-running is safe (matches 0 or 1 rows; either
--     way the table ends up with that user as admin).
--   * Safe before the user exists — if the email isn't in
--     profiles yet (e.g. the migration runs before the user has
--     signed in for the first time), the UPDATE matches zero rows
--     and is a no-op. Re-running after they sign up flips the
--     flag.
--   * Case-insensitive — uses lower() on both sides because
--     Supabase Auth stores emails in their original casing and
--     iOS / web invoke sign-up with whatever the user typed.
--
-- To grant admin to a different / additional user later, run the
-- same UPDATE in the Supabase SQL editor with their email.
-- A future admin API will do this via UI.

update public.profiles
  set is_admin = true
  where lower(email) = lower('mb@baykalconsulting.com');
