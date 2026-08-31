# Forensic / SitePhoto audit implementation

**Candidate build:** 6.38.5, branch codex/audit-reliability-improvements
**Baseline:** Build 6.37.1 at aa1a24eafde1d3e2ec7279e01069d919f82d3eeb
**Date:** August 30, 2026
**Delivery state:** Candidate validation snapshot; production release requires the separate PR, CI, database/storage cutover and hosting/TestFlight receipts. Test success alone does not certify deployment.

The independent audit has been followed by implementation across iOS, web, the shared schema, server and database migrations. All five improvement areas and all five feature additions have code and focused verification. This does not mean every operational acceptance criterion has been met: production rollout, physical-iPhone testing, large-report memory measurement and an operational backup drill remain separate release work.

The original audit remains the baseline record. Its earlier backlog reconciled to eight shipped items, three open items, three decisions/redesigns and three deliberately parked items. The two already-shipped view refactors are now correctly marked in the backlog; lazy painting is no longer described as full DOM virtualization.

## Ten audit findings

| Finding | Candidate correction | Evidence and qualification |
|---|---|---|
| F01 — profile privilege escalation / incomplete RLS history | Explicit RLS; authenticated profile updates restricted to display name. Shared configuration requires the intended role and atomic revision checks. | Local PostgreSQL permission tests and the separately applied/read-back profile-column hotfix; environment-specific receipts kept private. |
| F02 — finalized records still editable | Transactional access, revision, session-lock and freeze checks for manifests, uploads, commits, restores and deletion. Explicit owner/admin unlock; viewers can read and download existing authorized exports, while creating exports requires editor access. | Real SQL functions and Fastify negative cases, including receipt revocation and exact retry behavior. |
| F03 — queued saves erase remote edits | Each queued mutation keeps its own base; pending edits are rebased after acknowledgment and on retry. | DOM tests run the real hook and shared merge implementation. |
| F04 — AI checkpoint overwrites manual edits | Apply only AI-owned fields to the latest photo; use the same save coordinator and await server acknowledgment. | Delayed AI result preserves manual caption, favorite and bucket; completion waits for acknowledgment. No paid AI call. |
| F05 — failed iOS disk write reported saved | Acknowledge only successful atomic local persistence; retain visible pending data, block unsafe pulls, and retry without a false saved state. | Simulator fault injection covers failed save and successful retry. |
| F06 — failed plan replacement destroys original | Stage a unique replacement and commit matching metadata before retiring the old file; restore the original on failure. | Simulator test preserves the prior image and calibration. |
| F07 — incomplete evidence export reported successful | Required originals, plans and markup must match expected filenames and positive byte counts. Server/native exports fail before publication. Browser partial exports require explicit action and stay visibly incomplete. | Server stream/ZIP tests, real browser UI, actual ZIP-content DOM tests and native export tests. Browser ZIPs include revision/count/omission receipts. |
| F08 — canceled thumbnails never retry | Cancellation rolls back attempted IDs; expired signed image URLs have a refresh path. | DOM cancellation regression and browser photo checks. |
| F09 — non-atomic configuration revision checks | Conditional database updates and first-insert conflict handling; preserve drafts and present conflicts. | PostgreSQL configuration/library conflict tests and web/iOS branding acknowledgment tests. |
| F10 — clipped mobile actions / modal focus | Responsive card minimums, no nested buttons, shared modal focus entry/trap/restore and Escape behavior. | 390-pixel browser walkthrough; modal DOM regressions. This is not a whole-app accessibility certification. |

Additional integration fixes include unescaped filesystem paths for directories containing spaces, exact snapshot filename checks during exports, conditional immutable uploads, bounded object reads, safe CSV text, owner-aware freeze controls, custom iOS bulk-tag vocabulary and actual report-logo binary transfer.

## Five improvement areas implemented

1. **Owner and database safety.** Permission repair, service-only mutation RPCs, immutable upload receipts, daily/concurrent AI and export budgets, reduced telemetry and checked Keychain writes. Runtime production settings still need their approved cutover.
2. **Reliable saves and synchronization.** Shared web mutation coordination, iOS durability acknowledgments, atomic plan replacement, conflict-preserving settings and recovery boundaries.
3. **Finalization and trustworthy exports.** Server-enforced freeze, original/markup/plan completeness checks, explicit partial-browser receipts, protected version references and spreadsheet-formula neutralization. Original evidence bytes are retained.
4. **Performance.** Deferred heavy web modules and optional telemetry; cached/spatially indexed plan geometry; lazy cached thumbnails; background byte hashing; bounded PDF generation and serialized folder streams.
5. **Workflow and accessibility.** Photos / Plan / Review / Export / Details language, reusable export/recovery/preset dialogs, single-owner “Libraries” wording, report-layout parity, synced logo behavior and corrected backlog/parity documentation.

## Five additions implemented on web and iOS

| Addition | What the owner can do | Safety boundary |
|---|---|---|
| Project Health and Recovery | Inspect missing/registered/available files; verify cloud availability and retry native backfill. | Registry entries and a successful HEAD are not independent backups or verified hashes. |
| Protected version history | Preview prior versions, inspect differences and explicitly restore a selected version. | Restore checks revision, current access, locks, finalization and every required historical object. Legacy mutable objects are not retroactively certified. |
| Inspection sessions | Start, stop and resume visits without duplicating the project. | Previous visits are retained; resuming creates the appropriate new visit and does not reopen a stopped one through merge. |
| Cross-project search and saved filters | Find records by text/date/favorites across accessible projects; save, reuse and delete named filters. | SQL enforces access scope; library writes use revision checks; stale responses cannot replace newer results. |
| Inspection presets and checklists | Save reusable setup, preview changes before applying, append buckets/checklist items and retain report defaults. | Does not replace existing photographs or manual annotations. The separate legacy iOS global bucket library is still local. |

Shared manifest v4 defaults new fields when reading older projects. The TypeScript schema, validation, merges, Swift models, generated fixtures and parity matrix were updated together. Older clients must not write v4 projects or use the new upload contract.

## Verification

| Check | Result |
|---|---|
| Shared contract, migration/defaulting, merge and workflow tests | **81 passed / 18 suites** |
| Server SQL, authorization, recovery, upload, stream, PDF, branding and Free-plan operation tests | **161 passed / 13 files** |
| Web DOM behavior tests | **36 passed / 4 files** |
| iOS simulator tests | **22 passed**, including save/plan failure injection, object-store verification, account/context isolation, lock access and complete/incomplete folder export |
| Total regression tests | **300 passed** |
| Separate PostgreSQL transaction overlap checks | **3 passed**, using three connections with observed blocking |
| Server and web TypeScript | Passed |
| Web production build | Passed; one main chunk remains above the 500 kB warning threshold |
| iOS Debug simulator build/test | Passed with Xcode 26.6 and iOS 26.5; unsigned |
| Narrow permission hotfix rehearsal | Passed against 15 historical migrations in local PGlite; repeated application and subsequent migration 0016 both passed |
| Final independent review | Logo-preview races, exact AI snapshot binding, checkpoint errors, archive filename collisions, registry-only upload acknowledgments, UUID casing, native session/lock permissions, large folder queries and PDF read deadlines corrected and regression-tested |
| Working-copy preservation | Canonical checkout and its pre-existing edited verification document preserved |

JavaScript validation used Node 22.23.2 and pnpm 9.12.0. Database tests execute the actual migration SQL in PGlite with fake external identity/storage boundaries. They do not themselves prove simultaneous multi-connection PostgreSQL behavior. A separate PostgreSQL 17.11 run used three independent connections and observed actual lock waits: competing revision saves reject the loser; freeze-first revokes a pending upload; commit-first preserves evidence through freezing and exact retry. All three cases passed. This synthetic test is not a throughput stress test or a production/Supabase runtime certification. The real headless-Chrome PDF test verified decoded/aligned markup and exactly two pages; hosts without Chrome explicitly skip that optional integration test.

A first combined run exceeded the default PostgreSQL/WASM startup timeout while Xcode was running; a later run passed all assertions but exceeded Chrome's short cleanup timeout. Those integration setup/cleanup timeouts were increased to 30 seconds. The final combined run passed. These are correctness tests, not latency benchmarks.

Native access metadata is reset at account boundaries without deleting local evidence. A matching cached manifest revision still refreshes unknown permissions, including when local changes cannot yet be saved. Generation and account checks discard late list/GET/PUT/restore results; old queue work cannot clear a replacement account's work. Recovery and restore previews remain tied to the session that started them. Six additional simulator regressions exercise these boundaries with controlled responses and explicit completion/waiter checks. HTTP 401 remains a visible reauthentication error and does not automatically sign the user out.

Browser verification used the candidate UI and a synthetic local API: login/logout, non-admin owner controls, asset-health failures, Start/Stop/Resume, checklist and preset preview/apply, version diff and confirmed restore, saved search creation/reuse/deletion, export dialog keyboard behavior, and the deliberate one-missing-file export. No real project, account or object was created for these tests.

## Measured speed and resource changes

| Measurement | Baseline | Candidate | Interpretation |
|---|---:|---:|---|
| Main JavaScript | 795.27 kB / 238.21 kB gzip | 535.96 kB / 151.99 kB gzip | About **36% less compressed main JavaScript**. Optional and tab-specific chunks still download when used. |
| Workspace JavaScript | 632.88 kB / 183.00 kB gzip | 452.85 kB / 133.11 kB gzip | About **27% less compressed workspace JavaScript**. |
| CSS | 46.42 kB / 8.34 kB gzip | 47.19 kB / 8.48 kB gzip | Small increase from added workflow UI. |
| 100-marker geometry median | 0.335 ms | 0.196 ms | Same geometry in the synthetic benchmark. |
| 500-marker geometry median | 7.242 ms | 1.269 ms | Same geometry. |
| 1,000-marker geometry median | 28.698 ms | 2.763 ms | About **10.4× faster for this calculation**, not for the whole app. |
| Narrow web layout | Page 404 px at a 390 px viewport | Page 390 px; cards 342 px | Horizontal clipping reproduced and removed. |

The geometry benchmark used macOS native Swift with optimization, 21 runs per median and 40 additional correctness scenarios. It is not an iPhone frame-rate, battery or memory result; dense marker layouts can still have expensive worst cases.

PDF generation now consumes bounded HTML/image chunks instead of retaining all photo data URLs. Limits include ten logical pages and 32 MiB of registered image data per fetch batch, 12 MiB per streamed image, 48 MiB HTML and 80 megapixels per chunk, and 64 MiB / 1,000 pages for the PDF. One PDF renders per server process. The merged PDF still grows with output; no production peak-RSS result is claimed. See server/RECOVERY.md for exact behavior and clear over-limit failures.

Each PDF image's 30-second deadline includes SDK retries, response headers and the complete body. Folder exports query registrations in groups of at most 100 IDs. A synthetic 205-photo/205-plan case verified 820 required assets and 822 actual ZIP entries, including final-chunk assets; a failed later query aborts instead of publishing a partial archive. This is a correctness check, not production throughput measurement.

Build 6.38.5 keeps the existing Render Free plan. Each export worker now waits for its current job to settle before polling again, backs off from 5 to 60 seconds while idle, and resets to 5 seconds after claimed work. Across three idle workers the settled scan rate falls from 2,160 to 180 per hour, about 92% fewer scans by arithmetic, not a measured cost saving. New work can wait up to 60 seconds for discovery. PDF jobs release their browser at completion; page and browser cleanup each have a five-second deadline, with forced termination limited to the owned Chromium child. No global export-memory or interrupted-job recovery guarantee is implied. Scheduled Render wake pings are removed; the separate Supabase workflow is unchanged apart from its comment. Fifteen new server regressions cover these boundaries and the maintenance entrypoint.

## Dependency and operational limits

The production scan fell from **20 advisories (11 high, 6 moderate, 3 low)** to **one moderate advisory**, with no high or critical findings. The remaining advisory concerns OpenTelemetry 1.30.1 through Sentry 8. Its patched major is not a supported drop-in override for this Sentry version. The server now sets an explicit 16 KiB HTTP header limit; this mitigation does not mark the package advisory fixed. A tested supported Sentry upgrade remains follow-up work. [Maintainer advisory](https://github.com/open-telemetry/opentelemetry-js/security/advisories/GHSA-8988-4f7v-96qf).

AI request budgets reduce accidental cost, but are not exact dollar caps. This work did not evaluate model accuracy with paid calls or certify AI measurements. An owner-reviewed reference set remains appropriate.

The live storage probe passed with the actual server signer: the approved production-origin preflight succeeded, an initial conditional upload succeeded, an overwrite returned 412, omitting the signed condition returned 403, and readback preserved the initial bytes. Its disposable fixture was removed and absence verified. The independent local object copy passed a full checksum readback. The real public-data snapshot also passed 49 local migration/recovery assertions with existing rows unchanged. These are recorded in separate private/sanitized operational receipts.

Other unverified release checks: physical iPhone offline/camera/PencilKit behavior; large-project end-to-end latency and peak memory; production concurrency/load stress; full provider/Auth and independent-cloud backup restoration; App Store/TestFlight packaging and deployed source readback. No background-upload service, local-copy eviction, storage garbage collection or broad visual redesign was introduced.

## Release handoff

The narrowly scoped profile-column permission hotfix was applied and read back before PR publication on 2026-08-30. Authenticated users can update their display name but cannot update `is_admin`; service-role administration remains available. Registration settings were not changed. The private deployment receipt records the environment-specific evidence.

The full update requires migrations **0016 → 0017 → 0018 → 0019**, the R2 conditional PUT CORS header and matching server/web/iOS versions. Pause writes and drain legacy upload URLs before cutover. Do not blindly replay old migrations against a manually initialized database. Preserve local originals and a recoverable database/object baseline. Follow server/RECOVERY.md for the ordered release and smoke checks.

At this candidate checkpoint the existing Render Free service is quota-suspended. The owner chose to keep Free; no paid upgrade is needed for the prepared release procedure. The workspace had used 750.22 of its shared 750 free hours, with bandwidth and build minutes below their separate limits. Already-consumed hours cannot be recovered by code changes; the next calendar-month reset is September 1. Other workspace services are untouched.

Its old binary can resume when the monthly quota resets, so suspension is not a durable mutation gate. Main merge, automatic web/TestFlight release and migrations 0016–0019 remain held until deployment is permitted and the controlled API cutover is complete. The new standalone `server/maintenance.mjs` can serve the maintenance barrier on Free without importing the application, database or workers. Its 200 health response confirms only that barrier, not schema/API readiness. Verify the exact deployment, terminated old instances and drained legacy work before migrating, then restore the matching API start command. See [Free-plan operations](free-plan-operations.md). Neither that maintenance deployment nor the feature migration has been performed; no paid hosting change has been made.

After v4 and immutable evidence are written, a simple old-binary rollback is unsafe. Prefer a forward fix or a deliberately compatible build with writes paused. Retain all protected versions and object bytes. The local validation reported here did not deploy migrations, send user emails or call a paid model. Release operations and their exact Git/provider receipts are recorded separately; do not infer production or TestFlight delivery from these local checks.
