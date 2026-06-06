# Backup & restore drill

What's backed up, where, and how to recover from each failure class.
Pairs with `docs/ops-runbook.md` (day-2 ops) and `docs/deploy.md`
(first-time setup).

The guiding principle: **iOS local + iCloud is the primary archive;
the backend (Supabase + R2) is the team-shared copy.** Most "lost
data" scenarios are recoverable because the same data exists in two
or three places.

---

## What's stored where

| Data | Primary | Secondary | Tertiary |
|---|---|---|---|
| **Manifest** (project metadata, photo records, tags, AI analysis, distress, plan calibration) | iOS local JSON on disk | iCloud Drive (if enabled) | Supabase `projects.manifest` jsonb + `audit_log` history |
| **Photo / plan binaries** | iOS local files | iCloud Drive (if enabled) | Cloudflare R2 (`files` table is the registry) |
| **Tag library / AI rules** | iOS bundled defaults (in code) | Supabase `app_config` | — |
| **User accounts** | Supabase Auth | — | — |

Three independent backup mechanisms protect the manifest:

1. **Supabase point-in-time recovery (PITR)** — database-level
   snapshot + WAL replay. Requires the Supabase **Pro** plan
   (free tier has daily backups only, no PITR). Restores the whole
   DB to any second in the retention window.
2. **`audit_log` replay** — every AI tagging call (and, in future,
   every manifest write) records a row. Not a full manifest history
   today, but a growing trail.
3. **Pull from the iPad** — the device that captured a project still
   has the manifest + binaries locally (and in iCloud). Re-pushing
   from that device restores the server copy.

---

## Recovery procedures by failure class

### A. A single manifest field / photo record was overwritten

*Symptom:* someone edited a project on web, an iOS pull clobbered an
office edit (or vice-versa), and a caption / tag / position is wrong.

1. **Smallest hammer first.** If the correct value is still on one
   device, just re-enter it there and let it sync. Done.
2. If you need the prior server state: Supabase → Database → Backups
   → PITR (Pro plan) → restore to a timestamp before the bad write
   into a **branch / staging project** (never restore in place
   blindly). Pull the `projects.manifest` jsonb for the affected
   project id, extract the field, hand-apply it.
3. Cross-check against `audit_log` for the timeline of who wrote
   when.

### B. A whole project's manifest is corrupt / unparseable on the server

*Symptom:* web fails to render a project; server logs a zod
validation error on read, or the manifest jsonb is malformed.

1. The authoritative copy is on the **iPad that captured it**. On
   that device: Settings → Sync → "Sync now". `ManifestSyncer`
   re-pushes the local manifest, overwriting the corrupt server
   copy. This is the fastest path and needs no Supabase work.
2. If no device has it: PITR-restore the DB to a staging project,
   copy the project's row out, re-insert into production.

### C. A photo / plan binary is missing from R2

*Symptom:* web 404s on `/v1/projects/:id/photos/:id/image`; iOS shows
a placeholder; `[BinaryBackfill] … 404` in the console.

1. The binary exists on the **capture device** (local + iCloud) even
   when it never reached R2. On that device, signed in: the launch
   sweep's PhotoSyncer re-uploads any binary missing from R2 (it
   checks via `/v1/sync/files/check`). Settings → "Sync now" forces
   it.
2. Confirm the upload landed: the `files` table gets a row, and the
   web 404 turns into a 200.
3. If the binary is gone from EVERY device AND R2 — it's
   unrecoverable (it was never backed up anywhere). This is the one
   genuinely-lost case; it only happens if a photo was captured,
   never synced, and the device was wiped. iCloud is the safety net
   that makes this rare.

### D. Full project-level restore (project deleted / device lost)

1. **Device lost, iCloud intact:** sign into iCloud on a new device,
   install the app. The local JSON + binaries restore from iCloud
   Drive. Then sign into the backend → manifest + binaries reconcile.
2. **Device lost, no iCloud:** the backend has the manifest (Postgres)
   and the binaries (R2). On a fresh install, sign in → `ManifestSyncer`
   pulls the project list + manifests → `BinaryBackfillService` pulls
   the photos + plans from R2 (Build #5.49.1). Thumbnails regenerate
   locally (Build #5.53.1). This is the cloud-only recovery path and
   it works end-to-end as of #5.53.1.
3. **Project soft-deleted by accident:** `isDeleted` flips to true on
   trash. If it hasn't been hard-purged, restore = set it back to
   false (iOS trash → restore, or hand-edit the manifest jsonb).

### E. Total Supabase loss

1. Restore the project from the most recent PITR snapshot (Pro) or
   daily backup (free).
2. Re-run all migrations (`supabase/migrations/0001…000N.sql`) if
   restoring into a fresh project.
3. The `files` table (R2 registry) restores with the DB; the R2
   bucket itself is independent and unaffected.
4. iOS devices re-push manifests on next sync, reconciling anything
   newer than the snapshot.

### F. Total R2 loss

1. R2 holds the binaries; the `files` table holds the registry. If
   the bucket is lost but the DB survives, the registry rows point at
   objects that no longer exist → 404s on download.
2. Recovery: each capture device re-uploads its binaries on the next
   sync sweep (PhotoSyncer checks `/v1/sync/files/check`, finds the
   objects missing, re-uploads). Within a sync cycle of every device
   signing in, R2 repopulates.
3. Consider enabling **R2 object versioning** (Cloudflare dashboard →
   bucket → Settings) so an accidental delete is recoverable without
   the re-upload dance. Not enabled by default; flip it on for
   defense-in-depth.

---

## The drill (run this quarterly)

A backup you've never tested isn't a backup. Run this end-to-end
against a **staging** Supabase project / scratch R2 prefix — never
production:

1. **Cold-start recovery.** On a wiped simulator (no iCloud), install
   the app, sign in. Confirm: project list loads, a project's photos
   + plans backfill from R2, thumbnails appear. (Exercises path D.2.)
2. **Missing-binary recovery.** Delete one object from R2 by hand.
   Load the project on web → confirm the 404. Open the project on the
   capture device + "Sync now" → confirm the object re-uploads and
   the web 404 clears. (Exercises path C.)
3. **Manifest re-push.** Hand-corrupt a `projects.manifest` jsonb in
   a staging DB. Confirm web fails to render. "Sync now" from the
   capture device → confirm the manifest repairs. (Exercises path B.)
4. **PITR sanity (Pro only).** Restore the staging DB to a timestamp
   5 minutes ago into a branch. Confirm you can read a project row
   out of it.
5. Record the date + result of the drill at the bottom of this file.

### Drill log

| Date | Who | Result | Notes |
|---|---|---|---|
| _(none yet — first drill pending)_ | | | |
