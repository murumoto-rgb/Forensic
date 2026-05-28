# Phase 2 plan: photos visible on web + server-authoritative manifest

Closes the photo-display gap in the iOS↔web parity model and lays
the groundwork for web-side writes by flipping the source-of-truth
model. After Phase 1, the web app shows project metadata but no
images. After Phase 2, the web shows photos AND the server becomes
the authoritative source of truth for the manifest — iCloud Drive
is relegated to a useful local cache that handles offline capture
and free iOS-to-iOS device sync, but no longer "wins" on conflict.

This second piece — the source-of-truth flip — was added during
plan review when we asked "how would web edits propagate?" and
realized the answer was "they wouldn't without re-architecting
later." Doing the pull-from-server work now (when the iOS sync
layer is already open for the PhotoSyncer) costs ~1 extra day in
PR B and saves a painful migration when web writes ship.

## Architecture decisions

### Source of truth: server (Postgres + R2), not iCloud

Before this phase: iCloud was effectively iOS's source of truth.
The server had a copy of the manifest (pushed on save), but no
mechanism to push BACK to iOS. Web edits would have nowhere to go.

After this phase: the **server is authoritative**. iOS pulls from
the server on launch and on pull-to-refresh, applies any
server-newer revisions to local, then pushes any local-newer
revisions back. iCloud Drive still backs up the manifest + photos
on iOS for offline capability and multi-iOS-device sync, but if
iCloud and server disagree, **server wins**.

Conflict policy:
- Server's `revision` token is authoritative.
- iOS tracks the last revision it successfully synced per
  project (in UserDefaults, same store as ManifestSyncer already
  uses).
- On launch / pull-to-refresh, iOS calls `GET /v1/projects` →
  compares each project's server revision to its locally-cached
  revision. If server is newer, iOS pulls `GET /v1/projects/:id`
  and overwrites the local manifest.
- If iOS has local edits that haven't been pushed (offline
  capture), the next `ManifestSyncer.sync` PUT carries the local
  revision the user was working from. Server compares: match →
  accept and bump revision. Mismatch (someone else, including
  web, wrote in between) → 409, and iOS refetches + re-applies
  its local edits on top of the new server version.
- For Phase 2 the "re-apply local edits" path is simple: server
  manifest wins for anything web touched; iOS-local additions
  (new photos, new tags) merge in by appending. Anything more
  sophisticated (3-way merge of overlapping edits) defers to
  Phase 5's collaboration model.

### Object store: Cloudflare R2 (not Supabase Storage)

The user expects **hundreds of GB** of forensic-quality photos.
At that volume, Supabase Storage's storage + egress pricing is
an order of magnitude more expensive than Cloudflare R2.

|                    | Supabase Storage Pro    | Cloudflare R2     |
| ------------------ | ----------------------: | ----------------: |
| 100 GB stored      | $25/mo (Pro base)       | $1.50/mo          |
| 500 GB stored      | $33/mo                  | $7.50/mo          |
| 1 TB stored        | $46/mo                  | $15/mo            |
| Egress (downloads) | $0.09/GB after 250GB/mo | **$0** (no egress) |

R2 specifics that drove the choice:
- **Zero egress fees** — critical for an app that delivers PDFs
  with embedded photos to clients / insurance adjusters / the
  engineer's own re-downloads onto a new device.
- **S3-compatible API** — well-supported in Node via
  `@aws-sdk/client-s3`; we don't write R2-specific code.
- **Generous free tier** — 10 GB storage, 1M class-A ops, 10M
  class-B ops per month. Enough to develop and test before
  paying anything.
- **Same access-control model** — server holds R2 credentials,
  issues short-lived presigned URLs to clients. Identical to
  the Supabase Storage approach we would have used; only the
  backend changes.

The trade-off is a slightly more complex iOS upload flow
(server-issued presigned URLs instead of the Supabase SDK), but
the extra ~50 lines of server code is well worth the
order-of-magnitude cost savings.

### iCloud Drive: still useful, no longer authoritative

Phase 2 doesn't remove iCloud Drive from the iOS app. It still
backs up the manifest JSON and photo binaries on the user's
device, still syncs across the user's own iOS devices, and still
handles offline capture (you take a photo with no internet → it
saves to local + iCloud → the next sync pass pushes it to the
server when network returns).

What changes: **iCloud is no longer treated as the truth.** If
iCloud and server disagree, server wins. The user's existing iOS
trust model (iCloud is my backup) is preserved; the architectural
model (server is the source of truth) catches up to where the
multi-platform reality demands it.

This means no migration of existing projects. After Phase 2 ships:
- On next launch, iOS pulls from the server. For existing projects
  that iOS already pushed (Phase 1B-2 successfully synced them),
  server's revision matches what iOS has locally — no-op.
- Photo files start trickling up to R2 in the background as the
  PhotoSyncer walks each project's photos.
- Web project list begins populating with thumbnails over the
  first few minutes after launch.

User does nothing; the migration is automatic and backward-
compatible.

## Photo file flow

**iOS upload (new in Phase 2):**
1. ManifestSyncer pushes manifest as today.
2. PhotoSyncer walks `project.photos`, computes `objectKey =
   "<projectId>/<photoId>/<kind>"`, calls
   `POST /v1/projects/:id/files/upload-url` with file metadata
   (size, sha256, kind).
3. Server validates ownership + size limits, generates a
   presigned R2 PUT URL with 15-minute expiry, returns it.
4. iOS PUTs the binary directly to R2.
5. iOS calls `POST /v1/projects/:id/files/commit` so the
   server records the row in the `files` table.
6. iOS marks the photo as "uploaded" in a local UserDefaults
   map keyed by `objectKey` so subsequent sync passes skip it.

**iOS pull (new in Phase 2):**
1. On launch (after auth completes) and on pull-to-refresh:
   iOS calls `GET /v1/projects` → list of `(id, revision)` pairs.
2. For each project: compare server's `revision` to the
   locally-stored revision (the same UserDefaults map
   ManifestSyncer already maintains).
3. If server's revision is different and newer (server's
   `updated_at` > local's `updated_at`):
   - `GET /v1/projects/:id` → full manifest + revision.
   - Overwrite local Codable JSON file.
   - Update the local revision marker.
   - If `ProjectStore` has the project loaded in memory, reload
     it so the UI updates.
4. If iOS has pending local edits that haven't been pushed
   (offline-captured photos, manual tag edits), the next
   `ManifestSyncer.sync` PUT carries the iOS-local revision.
   Server compares: if it matches the current server revision,
   accept; if it doesn't (web wrote in between), 409 → iOS
   refetches + re-applies its local edits on top.

**Web display:**
1. Project-detail page mounts, fetches manifest via
   `GET /v1/projects/:id`.
2. For each photo, web requests
   `GET /v1/projects/:id/photos/:photoId/image`.
3. Server validates access, looks up the `files` row, returns
   a 302 redirect to a presigned R2 GET URL with 5-min TTL.
4. Browser fetches the bytes directly from R2.

**Deletion:**
- iOS soft-deletes a photo → photo moves to `trashedPhotos`
  array on the next manifest sync.
- After 30 days, iOS hard-purges trashed photos. The next sync
  removes them from the manifest. A periodic server-side
  cleanup task can be added later to GC orphaned R2 objects;
  for Phase 2 MVP, that's a TODO.

## Server-side additions

### Database
- New `files` table (object key, project_id, kind, size_bytes,
  sha256, uploaded_by, uploaded_at). RLS policies match the
  project-ownership model already in `projects`.

### Endpoints
- `POST /v1/projects/:id/files/upload-url` — validates request,
  returns a presigned R2 PUT URL.
- `POST /v1/projects/:id/files/commit` — records a successful
  upload in the `files` table.
- `POST /v1/sync/files/check` — given a list of `objectKey`s,
  returns which are already in R2 (so iOS can skip them).
- `GET /v1/projects/:id/photos/:photoId/image` — 302 to
  presigned R2 GET URL (full size).
- `GET /v1/projects/:id/photos/:photoId/thumb` — 302 to
  thumbnail variant (TBD: server-side generation or iOS-side
  upload of a pre-resized thumb).

(No new endpoint for iOS pull — uses the existing
`GET /v1/projects` and `GET /v1/projects/:id` from Phase 1.)

### Env vars (Render)
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_ACCOUNT_ID`
- `R2_BUCKET` (e.g. `forensic-photos`)

## iOS additions

### PhotoSyncer (binary upload)
- `PhotoSyncer.swift` — sibling to `ManifestSyncer`. Walks a
  project's photos, asks the server for upload URLs, PUTs to
  R2, commits.
- `UploadedFileTracker.swift` — small UserDefaults-backed
  store of "we have already uploaded objectKey X". Skips
  re-uploads.
- Hook into existing splash status (`store.loadStatus`):
  "Uploading photo 3 of 47…"
- Photo upload runs in the background — doesn't gate the
  manifest sync. If the manifest sync succeeds but a photo
  fails, the manifest is correct; the photo retries on next
  launch.

### ManifestSyncer pull pass (NEW)
- New method on `ManifestSyncer`: `pullAllFromServer() async`.
- Called from `SitePhotoApp.task` after `auth.bootstrap()` and
  `store.loadInitial()`. Also triggered by pull-to-refresh on
  the projects list (`refreshable` modifier).
- Walks server's project list, fetches manifests where server
  is newer, overwrites local files, refreshes
  `ProjectStore.activeProjects` in memory.
- On 409 from a PUT mid-pull (server changed while we were
  syncing), refetches and retries once.
- Errors surface via toast (existing pattern).

### Source-of-truth flip
- `ProjectStore.save(_:)`'s `onAfterSave` continues firing →
  ManifestSyncer.sync → push to server. Unchanged.
- Difference: the local file is no longer "the truth" — server
  is. iOS continues writing the local file on save (it's the
  local cache + iCloud-backed copy), but recognizes that the
  server's version might be ahead and pulls accordingly.

## Web additions
- Project-detail page at `/projects/:id`.
- Fetches manifest via existing `GET /v1/projects/:id`.
- Renders photo list with thumbnails (lazy-loaded from R2 via
  the redirect endpoint).
- Tap-to-enlarge lightbox.
- Filter bar: by floor plan, by bucket, by tag — same
  filters iOS exposes.

## PR breakdown

Per the "reduce merges, work iteratively" guidance, Phase 2 is
still 4 PRs. PR B grows by the iOS pull work.

| PR | Title | Scope | Rebuild needed |
| :- | :- | :- | :- |
| **A** | Phase 2 server + R2 + DB schema | Cloudflare R2 signup walkthrough, `files` table migration, all upload/download endpoints, env vars, presigned-URL helper. **Server-only.** | None (Render auto-deploys) |
| **B** | Phase 2 iOS PhotoSyncer + pull-from-server | PhotoSyncer + UploadedFileTracker (photo upload), ManifestSyncer.pullAllFromServer (server-authoritative model), splash-status integration, pull-to-refresh on projects list. **iOS-only.** Big single PR. | iOS rebuild |
| **C** | Phase 2 web project-detail + photo viewer | New `/projects/:id` route, photo grid, lightbox, filters. **Web-only.** Big single PR. | None (Vercel auto-deploys) |
| **D** | Phase 2 sign-off | Matrix updates for every photo row that flipped, parity sign-off comment. **Docs-only.** | None |

Hotfixes still get their own small PRs as needed.

## External services to set up (PR A walkthrough)

1. **Sign up at cloudflare.com** (~3 min) — free account, no
   credit card required for R2's free tier.
2. **Create R2 bucket** named `forensic-photos` (~2 min).
3. **Generate R2 API token** with read/write access to the bucket
   (~2 min).
4. **Note four values** (Account ID, Access Key ID, Secret
   Access Key, Bucket name) and paste back to me.
5. I add them to Render's env vars and ship PR A.

## Test plan

End-to-end verification after each PR:

- **After PR A:** server `/healthz` still 200. `POST /v1/projects/:id/files/upload-url` returns a presigned URL when authed. Manual `curl` PUT to that URL succeeds → object appears in R2 dashboard.
- **After PR B:**
  - On iPhone, take a photo, save the project. After a few seconds, the photo's `objectKey` appears in the R2 dashboard. Force-quit + relaunch → the PhotoSyncer doesn't re-upload (UploadedFileTracker remembers).
  - On a SECOND iPhone (or simulator) signed into the same account, launch the app → pull-from-server runs → projects appear with their full manifests pulled from the server (even though those projects were never created on this device).
- **After PR C:** on Vercel web URL, navigate to a project → photo thumbnails load. Tap-to-enlarge shows the full image. Filters work.
- **After PR D:** parity matrix shows ✅ for all photo-display rows.

## Future / explicitly out of scope for Phase 2

- **Web writes.** Phase 2 keeps web read-only. The pull-from-server work means web writes can land in any subsequent phase without an architectural change — they're "just" PUT support on the web side. Phase 5 (multi-user collaboration + edit-lock) was always when this was going to land in the original plan; Phase 2's pull-from-server just removes the blocker.
- **3-way merge of overlapping edits.** Phase 2's conflict policy is "server wins, iOS re-applies pending locals on top." For most cases (web edits a name, iOS edits a different field) this works fine. Truly overlapping edits (web and iOS both rename the same project) is a Phase 5 collaboration-model concern.
- **Photo deletion GC.** When iOS hard-purges trashed photos, R2 objects become orphaned. Phase 3+ adds a server-side cron that finds + deletes orphaned R2 objects.
- **Thumbnail generation.** Phase 2 MVP either (a) uploads a separate `thumb` object generated on iOS, or (b) serves the full image as the thumb. Final approach decided in PR B.
- **Web editing of photo metadata.** Phase 3+.
- **Markup overlay rendering on web.** Phase 3+.
- **Floor plan + distress on web.** Phase 3.
