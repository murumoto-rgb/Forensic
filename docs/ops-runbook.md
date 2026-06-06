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
| **iOS app** | TestFlight / device | SwiftUI; capture + on-device source of truth + iCloud backup | `git tag ios-release-*` or Xcode Cloud manual start |
| **Error reporting** | Sentry (optional) | Server + web exception capture | Active only when DSN env vars set |
| **Product analytics** | PostHog (optional) | Web pageviews + events | Active only when key env var set |

### The data-flow in one paragraph

iOS is the capture device and the local source of truth. On
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
- **Render cold start.** Free / Starter tiers spin down after ~15 min
  idle; the first request after idle takes ~20-30 sec. The web
  client's `api.ts` retries with backoff (0/2/5/10/15/25 sec) to
  cover this; if a request seems hung, it's likely a cold start —
  wait, don't restart.

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
3. Recent deploy? Check the deploy's commit against a known-good
   one; roll back via Render → Deploys → pick a prior successful
   deploy → "Redeploy".

### "Photos / floor plans won't load (web or iOS)"

1. Is it ALL projects or one? All → server / R2 issue. One → that
   project's binaries may not be in R2.
2. Web: open the browser console. A 404 on
   `/v1/projects/:id/photos/:id/image` means the `files` table has
   no row for that photo → it was never uploaded from any device.
   Fix: open the project on the iOS device that captured it; the
   launch sweep re-uploads via PhotoSyncer.
3. iOS: `[BinaryBackfill]` console lines tell you per-project missing
   counts. Settings → Sync → "Backfill missing files" forces a pull.
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

The manifest PUT uses optimistic concurrency (`expectedRevision`);
a stale write gets a 409. iOS retries once by refetching. The lock
model exists server-side but isn't surfaced in the iOS UI yet, so
simultaneous edits from two devices are possible. For now: coordinate
out-of-band. Recovery of overwritten data: see
`docs/backup-restore-drill.md` (audit-log replay).

---

## Deploys + rollback

- **Web / server:** push to `main` → auto-deploy. Rollback = Render
  → Deploys → Redeploy a prior build; Vercel → Deployments → promote
  a prior deployment to production.
- **iOS:** never auto-deploys. `git tag ios-release-<n> && git push
  origin ios-release-<n>` triggers the Xcode Cloud workflow, or use
  App Store Connect → Xcode Cloud → Start Build. Merging to `main`
  does NOT ship a new TestFlight build.
- **Migrations:** never auto-run. Paste the SQL file into Supabase
  → SQL Editor → Run. Migrations are forward-only; there are no
  down-migrations (recovery is via PITR — see the backup doc).

---

## Routine maintenance

- **Anthropic cost check:** Supabase → `audit_log` table, or
  `select model, count(*), sum(cost_estimate_hundred_thousandths_of_cents)/10000000.0 as usd
  from audit_log where event_type='ai_tag_photo' group by model;`
- **R2 storage check:** Cloudflare dashboard → R2 → bucket → metrics.
  Zero egress fees, so the only cost is stored GB.
- **Supabase row counts:** Dashboard → Database → check `projects`,
  `files`, `audit_log` growth. `audit_log` is append-only and will
  grow unbounded; prune old rows manually if it ever matters
  (it won't at this team's scale for years).
