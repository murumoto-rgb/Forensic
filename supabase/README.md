# supabase

Database migrations and configuration for the Forensic Supabase
project.

## Migrations

SQL files in `migrations/`, numbered sequentially
(`0001_initial.sql`, `0002_audit_log.sql`, …). Each file is
**idempotent at the level of its own changes** — i.e. it assumes
the previous migrations have already run, and adds its own
delta on top.

### Running a migration

1. Open Supabase Dashboard → **SQL Editor** (left sidebar
   `>_` icon) → **New query**.
2. Paste the entire contents of the migration file.
3. Click **Run** (or ⌘+Enter).
4. Confirm success: bottom panel shows "Success. No rows
   returned" or similar.
5. Verify the schema landed: Dashboard → **Table Editor** →
   confirm the new tables / columns appear under the `public`
   schema.

### Phase 1 migrations

- `0001_initial.sql` — `profiles` + `projects` tables, plus
  the auto-profile-on-signup trigger and basic RLS policies.

Later phases append additional migrations; we never edit a
migration file after it's been run on production.
