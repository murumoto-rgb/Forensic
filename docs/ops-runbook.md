# Ops runbook

Day-2 operations for the Forensic stack. This is the
"something looks wrong, what do I do" guide. For first-time
deploy + env-var setup see `docs/deploy.md`; for data recovery
see `docs/backup-restore-drill.md`.

---

## What's running where

| Component | Host | What it is | Deploys from |
|---|---|---|---|
| **Postgres + Auth** | Supabase (`forensic` project) | Manifest blobs (`projects.manifest` jsonb), `files` registry, `app_config`, `audit_log`, user accounts | Migrations applied manually via SQL Editor |
| **API server** | Render (`forensic-server`) | Fastify; auth, manifest CRUD, presigned-URL minting, AI proxy, app-config | Auto-deploy on push to `main` |
| **Web SPA** | Vercel (`forensic-web`) | React + Vite static build | Auto-deploy on push to `main` |
| **Photo / plan binaries** | Cloudflare R2 (`forensic-photos` bucket) | Full images, thumbs, markup overlays, plan renders | Written by clients via presigned PUT |
| **iOS app** | TestFlight / device | SwiftUI; capture + local files; device/iCloud recovery must be verified separately | Xcode Cloud manual branch start (verify the live workflow) |
| **Error reporting** | Sentry (optional) | Server + web exception capture | Active only when DSN env vars set |
| **Product analytics** | PostHog (optional) | Web pageviews + events | Active only when key env var set |

### The data-flow in one paragraph

iOS is the capture device; local and server copies can differ. On
`save(_:)` it pushes the manifest to the server (`ManifestSyncer`)
and uploads photo/plan binaries to R2 (`PhotoSyncer`). The server
stores the manifest jsonb in Postgres and records each R2 object in
the `files` table. Web reads everything through the server: manifest
from Postgres, binaries via presigned R2 GET URLs. A device that
pulled a manifest but lacks the binaries backfills them from R2
(`BinaryBackfillService`).

---

## Health checks

- **Server up?** `curl https://forensic-server.onrender.com/healthz`
  → `{"status":"ok","serverManifestSchemaVersion":N,"gitSha":"…","gitShaShort":"…"}`.
  The `gitShaShort` confirms which build is live — compare it to the
  merge commit on `main` after a deploy.
- **Web up?** Load the Vercel URL. The footer shows the build number
  + commit (embedded at compile time by `vite.config.ts`).
- **Render cold start versus suspension.** Free instances spin down
  after 15 minutes idle and can take about a minute to restart; paid
  compute does not have this Free-instance limit. A quota suspension
  does not clear through retries: the workspace receives 750 free
  instance hours per calendar month, then Free services pause until
  the next month or a paid compute upgrade. Confirm the dashboard
  reason before treating a 503 as an ordinary cold start.
  [Render Free-instance limits](https://render.com/docs/free).

---

## Reading logs

- **Render:** Dashboard → `forensic-server` → Logs. Pino-formatted
  JSON in production. Grep for `"level":50` (error) or `"level":40`
  (warn). The AI proxy logs `"AI tag — completed"` / `"AI tag —
  Anthropic error"`. The files-check route logs sub-batch failures
  with `chunkOffset`.
- **Vercel:** Dashboard → `forensic-web` → Logs (these are mostly
  static-asset serving; the SPA's runtime errors go to the browser
  console / Sentry, not Vercel).
- **Supabase:** Dashboard → Logs → Postgres / API / Auth. Useful for
  RLS-denied reads and slow queries.
- **iOS:** Xcode console when tethered. Prefixed lines:
  `[PhotoSyncer]`, `[BinaryBackfill]`, `[APIClient]`,
  `[AuthService]`.
- **Sentry (when configured):** sentry.io → Issues. Server errors
  carry method / url / userId; web errors carry the user id.

---

## Common incidents

### "The server is down / every request 500s or times out"

1. `curl …/healthz`. If it hangs ~30 sec then responds, it was a
   cold start — not an incident.
2. If it returns 5xx or never responds: Render → Logs. Look for a
   boot-time crash. Most likely a **missing / malformed env var** —
   the server `process.exit(1)`s on bad env (see `env.ts`) and the
   log says exactly which var.
3. Recent deploy? Check the serving commit and database migration
   state. Do not redeploy an arbitrary older build: after migration
   0017, `aa1a24e` is unsafe for writes. Pause writes and use a
   compatible forward fix or rollback build; see the release gate below.

### "Photos / floor plans won't load (web or iOS)"

1. Is it ALL projects or one? All → server / R2 issue. One → that
   project's binaries may not be in R2.
2. A 404 does not prove an asset was never uploaded. Preserve the
   manifest, registry and available originals before changing anything.
   On the matching candidate server, use project health with
   `?verify=true` to distinguish missing, unregistered and unverified
   assets. Registry presence alone does not prove bytes exist.
3. Inspect a preserved device copy before allowing it to sync. Do not
   force "Sync now" as a recovery shortcut: it may change metadata,
   and device/iCloud completeness is unverified. Use the reviewed
   recovery procedure in `docs/backup-restore-drill.md`.
4. 502 on the photo endpoint = R2 fetch failed server-side. Check
   the R2 credentials env vars on Render and the R2 dashboard for
   bucket availability.

### "AI tagging returns 503 'AI tagging not configured'"

The `ANTHROPIC_API_KEY` env var isn't set on Render. Add it
(Render → Environment) and the route activates on the auto-redeploy.

### "AI tagging returns 503 'credentials rejected'"

The `ANTHROPIC_API_KEY` is set but invalid / revoked. Re-issue at
console.anthropic.com and update the Render env var.

### "AI tagging on web says 'no tag library on the server yet'"

The `app_config` table has no `tagLibrary` row. Open the iOS app
once while signed in — `AppConfigSyncer` seeds the defaults on launch
(Build #5.47.1). Or push a library by editing one on iOS / the web
admin page (`/admin/tag-library`).

### "PhotoSyncer logs `sync-files-check chunk failed … 500`"

Fixed in Build #5.55.1 (server-side sub-batching). If it reappears,
the server isn't on a build that includes #5.55.1 — check
`/healthz` `gitShaShort` against the merge commit.

### "Web shows stale data after an iOS edit"

Web reads the manifest on page load; it doesn't live-subscribe yet.
Refresh the page. (Realtime push is a future enhancement.)

### "Two people edited the same project and one lost work"

Preserve both copies and stop further edits. The candidate uses revision
checks and session locks; conflict responses require review, not a forced
overwrite. Its version preview/restore can recover a complete retained
snapshot, but `audit_log` is not a full backup or manifest replay source.
Follow `docs/backup-restore-drill.md`; verify the serving build before
assuming candidate protections are deployed.

---

## Deploys + rollback

- **Web / server:** automatic deployment does not coordinate a schema
  cutover. For migrations 0016–0019, follow `server/RECOVERY.md`: enforce
  old-server mutation/job admission shutdown, drain uploads and jobs,
  stop old workers, and wait 15 minutes after the last legacy PUT URL
  issuance plus any in-flight transfer. Apply migrations in order, then
  switch all instances to the matching build before resuming writes.
  No rolling old/new overlap and no writable `aa1a24e` rollback after
  0017. Pause writes on failure; retain history and object bytes.
- **iOS:** merging to `main` does not ship TestFlight. The live SitePhoto
  workflow checked on 2026-08-30 accepts manual branch starts and has no tag
  start condition; the older tag-trigger description is historical. Start the
  reviewed, merged revision through Xcode Cloud and verify its source SHA,
  successful archive, Apple processing `VALID`, and access for the existing
  internal test group. A tag or successful upload alone is not delivery.
- **Migrations:** reconcile the actual schema and migration ledger first;
  historical manual SQL must not be blindly replayed. Apply only the
  reviewed missing migrations, transactionally, while the release gate
  is held. Do not assume PITR is enabled or available as rollback.
- **Client upgrade:** the candidate returns 426 for legacy uploads and
  for v4-project writes that declare v3 or omit raw checklist/session
  arrays, including an old codec echoing v4. Older reads remain allowed.
  Release the matching iOS/web clients before reopening uploads.
- **Quota suspension is not a migration lock.** A suspended Free
  service can resume its old binary at the next monthly reset. Do not
  apply the new schema or automatically release new clients on the
  assumption that a temporary 503 permanently stops old writers.
  Finish candidate checks and backups first, then obtain any required
  compute-cost approval and establish the enforced cutover gate.
- **Backup gate:** retained version history is not an independent copy.
  Free Supabase projects need manual/off-site dumps; PITR is a paid
  add-on. R2 has no supported S3 bucket-versioning switch. Verify the
  separate database/object backup and isolated restore procedure in
  `docs/backup-restore-drill.md`; candidate tests do not certify it.

---

## Routine maintenance

- **Anthropic cost check:** Supabase → `audit_log` table, or
  `select model, count(*), sum(cost_estimate_hundred_thousandths_of_cents)/10000000.0 as usd
  from audit_log where event_type='ai_tag_photo' group by model;`
- **R2 storage check:** Cloudflare dashboard → R2 → bucket → metrics.
  Egress bandwidth is free; storage and operation requests can still
  be billed beyond included usage. Infrequent Access also has retrieval
  charges. [R2 pricing](https://developers.cloudflare.com/r2/pricing/).
- **Supabase row counts:** Dashboard → Database → check `projects`,
  `files`, `audit_log` growth. `audit_log` is append-only and will
  grow unbounded; prune old rows manually if it ever matters
  (it won't at this team's scale for years).
