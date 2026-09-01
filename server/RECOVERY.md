# Evidence recovery and workflow backend

This candidate requires migrations **0016, 0017, 0018, and 0019 in that order**, before deploying the matching server. The repository tests apply SQL to local PGlite; they do not deploy migrations or certify an existing database's migration ledger. Do not run production DDL without the coordinated release approval and a recoverable database backup.

## Coordinated release

1. Review the existing schema, grants and migration ledger. A historical database may have manually applied SQL with no recorded migration entries: do not blindly replay 0001–0015. A narrow profile-column permission fix can be released independently of the schema-v4 cutover, keeping normal display-name updates and service-role administration available.
2. Preserve the database and object-store recovery baseline, rehearse the upgrade in an isolated environment, and test competing transactions with a full PostgreSQL server. Local PGlite is useful functional evidence but uses a single connection.
3. Add `If-None-Match` to the bucket's allowed browser PUT headers without removing existing headers/origins. Check an allowed new-object PUT, a rejected overwrite and the preflight response. See [R2 CORS configuration](https://developers.cloudflare.com/r2/buckets/cors/).
4. Enforce a pause on old-server mutations and new job admission; asking clients to stay idle is insufficient. Stop issuing legacy PUT URLs, drain in-flight uploads/commits and export jobs, and stop old workers. Wait at least 15 minutes after the **last legacy URL issuance**, plus completion of any transfer already in flight. API shutdown does not revoke an R2 URL. Keep local originals and an independent copy throughout the transition.
5. With old writes/workers quiescent, apply 0016–0019 in order, transactionally per migration. If any step fails, keep writes disabled. Migration 0017 is not backward compatible with a writable `aa1a24e`: its old delete handler can remove R2 bytes before the new database trigger rejects deletion, and its old upload commits omit the new filename mapping.
6. Replace every old server instance before enabling v4 client writes. Do not use a rolling deployment that mixes `aa1a24e` and the candidate after the migration or after versioned writes begin. Deploy the matching web and make the matching iOS build available before resuming uploads. Old upload requests intentionally receive 426. Verify the schema, grants, current-file view and actual serving SHA before reopening traffic.
7. Verify non-admin privilege denial, frozen manifest/upload denial, config conflicts, save/restore conflicts, immutable upload/commit, required-file export failures, health checks and branding on the released versions. Use only isolated test data for destructive restore/delete drills; never delete or corrupt real evidence to prove recovery. See the implementation report for physical-device checks.

Rollback is not a schema downgrade. Do not reopen writes on `aa1a24e` after migration 0017, even if no v4 write has occurred yet. After v4 writes and immutable object registrations begin, old server/client code can also lose new fields or select the wrong asset. Prefer a forward fix; if a deployment must be reverted, first stop writes and use an intentionally compatible build. Retain the added database tables, upload receipts, version rows and all object bytes. Do not delete historical assets or run automatic garbage collection as rollback.

These are candidate release requirements, not evidence that deployment, an independent backup, or a physical-device/iCloud recovery drill has completed. Protected version history shares the live database and object store; it is not an independent backup. Preserve off-site database dumps and object copies, and verify restoration in isolation. Free Supabase projects need manual exports/off-site backups; PITR is a paid add-on, not included simply by having Pro. [Supabase backup documentation](https://supabase.com/docs/guides/platform/backups). R2 does not implement `GetBucketVersioning` or `PutBucketVersioning`; there is no S3 bucket-versioning switch to enable. [R2 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/). See [the backup drill](../docs/backup-restore-drill.md) before any recovery operation.

### Keeping the current Free compute plan

Build 6.38.5 adds a dependency-free `server/maintenance.mjs` entrypoint, so
Render's paid maintenance feature is not required for the cutover. Deploy
that exact reviewed entrypoint while the old schema is intact, confirm its
SHA and the termination of old instances/workers, then hold it through the
legacy URL drain and migrations. Quota suspension itself cannot substitute
for that verification. See [Free-plan operations](../docs/free-plan-operations.md).

Idle queue polling now backs off to 60 seconds, with one pending tick per
worker; claimed work returns to five seconds. PDF browser/page cleanup is
bounded and Chromium is released after every job. New-job pickup may take
up to a minute after idle. Export contents and existing limits are unchanged;
no 512 MB peak-memory or transparent interrupted-job recovery is claimed.

## Storage and rollout

- New upload URLs and commits require `immutable: true` and `sourceFilename`. Older requests get HTTP 426. The unique object key is protected by a signed `If-None-Match: *` condition. Clients must send the returned `requiredHeaders`; R2 CORS must allow `If-None-Match` for browser uploads.
- Both manifest PUT paths reject HTTP 426 when the stored project is v4 and the incoming project is below v4 or omits the raw `inspectionChecklist` / `inspectionSessions` arrays. Checking raw fields before validation defaults also catches an old codec that echoes version 4 but drops unknown fields. Older reads and writes to still-v3 projects remain allowed; this guard does not make old uploads compatible.
- Previously issued legacy PUT URLs can remain usable for their original 15-minute lifetime. Drain that window during rollout. Legacy registrations are readable but are explicitly **not** restorable immutable evidence. This release does not certify earlier bytes.
- Commit performs an R2 HEAD with a 10-second deadline and verifies byte length. `sha256` remains a client-supplied, **unverified** declaration, not cryptographic integrity evidence.
- `files` retains every committed object. `is_current` chooses the active object for a project/entity/kind/**filename**. `current_project_files` also joins the current manifest, so a pending upload under another filename cannot replace an existing manifest asset.
- Version snapshots store exact object keys and lengths atomically with each manifest revision. Once the final declared immutable asset is committed, an additional complete checkpoint is recorded if needed. It has its own version ID but may share a manifest revision. Incomplete snapshots remain unchanged and readable. No retention cleanup or garbage collection is enabled.
- A project can be permanently deleted only after it is trashed, is not frozen, and passes the transaction's revision/access/lock checks. Database deletion happens before best-effort object deletion: cleanup failures may leave orphan storage, never destroy bytes for a project whose deletion was rejected.

## API contracts

- `GET /v1/projects/:id/health` returns registry state for all declared originals, thumbnails, markup images/drawings, trashed-photo assets, and plans. `?verify=true` performs bounded HEAD checks (six in flight). A storage error or length mismatch is `unverified`, not `missing`. Registry presence does not prove current storage availability.
- `GET /v1/projects/:id/versions` returns the newest 100 summaries. Older rows are retained. `GET .../versions/:versionId` returns a snapshot for preview. List `restorable` is based on immutable registry references; restore additionally checks live storage.
- `POST .../versions/restore` accepts `{versionId, expectedRevision}`. Every required historical object must pass HEAD/length verification before the transaction changes the manifest and pointers. Storage errors, missing objects, frozen state, revision conflicts and unauthorized callers leave the project unchanged.
- `GET /v1/projects/:id/files/:entityId/:kind?filename=...` is the generic download resolver. A supplied filename mismatch returns 409. It supports originals, thumbnails, both markup kinds and plans; viewers may read.
- `GET/PUT /v1/me/workflow` stores the caller's private library. PUT uses `{library, expectedRevision}` (null only for first write).
- `POST /v1/search` applies owner/member/admin scope within SQL, literal text search, date/favorites filters, and bounded offset pagination (maximum 100 hits).
- Clients should send `X-Client-Session` on manifest saves, uploads/commits, heartbeat and restore. A live lock with a session token can only be used by that same session. iOS lock acquisition must send the same value as `clientSession`.

## Cost and queue limits

Migration 0018 enforces database-backed admissions: AI defaults to 200 requests per user per UTC day and four concurrent requests; exports allow two active jobs per user, five globally and 50 admissions per user per day across both queue APIs. AI limits are configurable within the server's bounded environment ranges; they are request budgets, not a guarantee of an exact dollar spend. Abandoned AI leases expire after five minutes, while daily charges are not refunded. The AI provider call has no automatic retry and a 4,096-token output cap. Keep usage review proportionate to this single-owner app.

## Branding and folder-export integrity

The admin-only branding upload route accepts a bounded PNG and writes a new immutable object key. Uploading does not publish it: the report-branding configuration must also pass its revision check. Clients retain unsaved drafts on conflict, and reports fail if the configured logo is unavailable. No logo is stored under a synthetic project identity.

Folder exports require the snapshot's exact filenames for originals, plans and both markup kinds. The server rejects changed registrations before presigning or streaming, checks actual stream lengths, serializes sources, and never records Done after a missing/short/failed source or invalid final ZIP HEAD. The native client stages a complete folder before atomic publication. The browser keeps partial results visibly incomplete; deliberate partial downloads have an `INCOMPLETE export` filename and an `EXPORT_STATUS.txt` receipt identifying the revision, required-file counts and omissions. The receipt is a completeness record, not a verified content-hash certificate or independent backup.

## Validation and limits

Run `pnpm exec vitest run server/tests` and `pnpm --filter @forensic/server typecheck`. Recovery tests load the migration history into real in-memory PostgreSQL and inject actual Fastify routes, with a fake object store and identity provider; no production credentials or paid services are used.

PGlite tests use one database connection and are not a multi-connection concurrency stress test. The transaction's parent-row lock serializes saves, commits, lock acquisition, restore and deletion. The separate live R2 conditional-upload/CORS probe passed; matching migration deployment and deployed-source verification still need the controlled release. External storage deletion or account compromise remains outside PostgreSQL's transaction; HEAD is a point-in-time availability check, not a cross-service atomic guarantee.

## PDF export bounds

PDF report HTML is produced by an async generator and consumed directly by the Puppeteer worker. Global bucket grouping and contact-sheet pagination occur before chunking, so chunk boundaries do not repeat dividers or reorder photographs. Reports require original photo objects, not navigation thumbnails. Plans load one at a time (one or two rendered pages for the selected plan mode). Metadata tables are emitted in batches of 100 rows; each batch starts with its table heading.

The renderer buffers at most ten logical pages and 32 MiB of registered image data per fetch batch, with six downloads in flight. Each streamed image is limited to 12 MiB and a 30-second download deadline. A generated HTML chunk is limited to 48 MiB and 80 million decoded image pixels; smaller transport chunks are used without altering contact-sheet page composition. A single page over the image/pixel limit fails with an instruction to reduce photos per page. Six 12-megapixel photos fit the pixel limit. Images exceeding the individual byte limit must be reduced before export.

The worker validates actual Chromium image decoding, consumes one HTML chunk before requesting the next, and incrementally merges PDFs. The merged `pdf-lib` document still grows with output size: source/final PDF bytes are limited to 64 MiB and the result to 1,000 pages. These are structural resource limits, not a production RSS benchmark or a guarantee for every server size. Only one PDF job renders at a time in each server process. Progress reports completed chunks while the dynamic total is unknown, then records the final total on success.

Registry failures, missing originals/plans, mismatched byte lengths, unsupported/malformed images, and Chromium decode failures abort the export. No partial PDF is uploaded or marked Done. `server/tests/pdfStreaming.test.ts` exercises generator backpressure, bounded downloads, bucket ordering across boundaries, plan bounds, original-only resolution, page limits, and the actual worker control flow with mocked Chromium/storage (not a real Chromium performance measurement).

## Upload receipt and work-budget regression coverage

Migration 0019 authorizes and locks the project **before** locking a pending receipt, matching the project-freeze trigger's lock order. A consumed receipt may be replayed as an exact no-op after expiry or freezing, but only while the original actor still has project write access and satisfies the session-lock guard. Replays cannot reactivate an older asset pointer. Unconsumed receipts revoked by freezing remain invalid after unlock. Receipt fields are compared null-safely, and issuance TTL is limited to 1–900 seconds.

`getObjectBytes` has one 60-second maximum deadline spanning SDK/header latency and complete body consumption, including a body that stalls after sending partial bytes. Timeout aborts the SDK request and destroys the stream. Actual bytes are counted even without Content-Length; incomplete bodies fail. The shared maximum is 50 MiB and callers may set a lower `maxBytes` or shorter `timeoutMs`. With the AI route's no-retry 60-second Anthropic timeout, these two operations consume at most 120 seconds of the five-minute AI lease. The route bounds its separate database admission/read/release operations.

`workBudgetsAndReceipts.test.ts` loads every migration through 0019 and exercises the real SQL functions/triggers: AI daily and concurrent admission, wrong-actor release, abandoned-lease expiry without refunds, UTC-day separation, service-only execution, and shared legacy/unified export limits (two active per user, five globally, 50 daily admissions). Completed/failed jobs free concurrent capacity but retain daily charges; mirrored completed artifacts are not charged again.

Concurrency qualification: the repository tests use single-connection PGlite. They inspect the installed commit function's lock ordering and execute both freeze-first and commit-first outcomes, including exact retries and access revocation. A separate synthetic PostgreSQL 17.11 validation used three independent backend connections and observed `pg_blocking_pids` wait edges before releasing each blocking transaction. Competing revision CAS, freeze-before-receipt-commit and receipt-commit-before-freeze all passed against migrations 0001–0019 under the service role. The temporary local server was stopped afterward. This proves those three overlapping transaction cases, not throughput stress, Supabase runtime equivalence or cross-service atomicity. `r2Read.test.ts` exercises stalled headers, a partially delivered/stalled body, cleanup, byte limits and truncation using fake transport and deterministic timers; no object-store request is made.

PDF parity verification: marked photos occupy adjacent clean/marked contact-sheet
cells and require their registered PNG overlay; editable PencilKit source is not
used for rendering. Selected floors are filtered before registry/storage reads,
with excluded-floor photos retained in the trailing Unlocated section. Empty
separate/distress-only layers do not create blank plan pages. Each job snapshots
report branding once and fails if the configured logo cannot be loaded. A failed
snapshot/registry filename match also fails the job instead of substituting a
concurrently replaced asset. The original source buffers remain bounded; distinct
original/overlay decoded images count toward the 80-megapixel per-chunk budget.
The optional `pdfBrowser.test.ts` integration test launches a separate headless
Chrome instance (`PUPPETEER_EXECUTABLE_PATH`, or the installed macOS Chrome app),
verifies image decoding/alignment and the generated PDF's two-page count, and
explicitly skips on hosts without that executable. It is a small correctness
smoke test, not a large-project memory benchmark.
