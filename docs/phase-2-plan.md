# Phase 2 plan: photos visible on web

Closes the photo-display gap in the iOS↔web parity model. After
Phase 1, the web app shows project metadata but no images — the
manifest lives on the server, the JPEGs live only on the
iPhone's iCloud Drive. Phase 2 adds a second copy of every
photo into an object store the web can read from.

## Architecture decisions

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

### iCloud Drive stays as the iOS primary

Phase 2 *adds* R2 as a secondary copy for web display. iCloud
remains the iOS-side source of truth — the offline-capable
camera capture flow, the per-device sync, the existing iCloud
manifest backup, all unchanged. The only new behavior on iOS
is "after `ProjectStore.save(_:)` lands the manifest, upload
any photos that aren't yet in R2."

This means **no migration of existing projects**. After Phase 2
ships, photos trickle up to R2 in the background:
- On next launch (with sign-in), the PhotoSyncer walks every
  project and uploads any photo whose `imageFilename` isn't in
  R2 yet.
- On every save, any new photos for that project upload
  immediately.

User does nothing; the web project list gradually populates
with thumbnails over the first few minutes after launch.

### Photo file flow

**iOS upload:**
1. ManifestSyncer pushes manifest as today.
2. PhotoSyncer walks `project.photos`, computes `objectKey =
   "<projectId>/<photoId>/photo"`, calls `POST /v1/projects/
   :id/files/upload-url` with file metadata (size, sha256, kind).
3. Server validates ownership + size limits, generates a
   presigned R2 PUT URL with 15-minute expiry, returns it.
4. iOS PUTs the binary directly to R2.
5. iOS calls `POST /v1/projects/:id/files/commit` so the
   server records the row in the `files` table.
6. iOS marks the photo as "uploaded" in a local `UserDefaults`
   map keyed by `objectKey` so subsequent sync passes skip it.

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

### Env vars (Render)
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_ACCOUNT_ID`
- `R2_BUCKET` (e.g. `forensic-photos`)

## iOS additions
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
4 PRs:

| PR | Title | Scope | Rebuild needed |
| :- | :- | :- | :- |
| **A** | Phase 2 server + R2 + DB schema | Cloudflare R2 signup walkthrough, `files` table migration, all upload/download endpoints, env vars, presigned-URL helper. **Server-only.** | None (Render auto-deploys) |
| **B** | Phase 2 iOS PhotoSyncer | PhotoSyncer, UploadedFileTracker, splash-status integration, hook into `ManifestSyncer.sync`. **iOS-only.** Big single PR. | iOS rebuild |
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
- **After PR B:** on iPhone, take a photo, save the project. After a few seconds, the photo's `objectKey` appears in the R2 dashboard. Force-quit + relaunch → the PhotoSyncer doesn't re-upload (UploadedFileTracker remembers).
- **After PR C:** on Vercel web URL, navigate to a project → photo thumbnails load. Tap-to-enlarge shows the full image. Filters work.
- **After PR D:** parity matrix shows ✅ for all photo-display rows.

## Future / explicitly out of scope for Phase 2

- **Photo deletion GC.** When iOS hard-purges trashed photos, R2 objects become orphaned. Phase 3+ adds a server-side cron that finds + deletes orphaned R2 objects.
- **Thumbnail generation.** Phase 2 MVP either (a) uploads a separate `thumb` object generated on iOS, or (b) serves the full image as the thumb. Final approach decided in PR B.
- **Web editing of photo metadata.** Phase 3+.
- **Markup overlay rendering on web.** Phase 3+.
- **Floor plan + distress on web.** Phase 3.
