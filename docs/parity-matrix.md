# iOS ↔ Web Parity Matrix

This file is the **living source of truth** for which features exist on
which platform. It must be updated in the **same PR** that changes a
feature's behaviour on either platform. The GitHub PR template asks for
this explicitly; CI's parity contract test (see `packages/shared/`)
enforces schema-level parity at build time.

## Legend

- ✅ Implemented and shipping
- 🚧 Candidate / in progress (not yet shipped; link the branch or PR)
- 📋 Planned (Phase N)
- ❌ Out of scope for this platform (must include a one-line reason
  under "Platform exclusions" below)
- n/a Doesn't make sense on this platform

## Schema parity

Both platforms speak the same manifest. The canonical schema lives in
`packages/shared/src/manifest.ts`; iOS Codable structs mirror it. The
parity contract test in `packages/shared/tests/ios-parity.test.ts`
fails CI if iOS adds a field without updating the TS types (or vice
versa). Every schema change bumps `manifestSchemaVersion` and lands in
**both** stacks in one PR.

Candidate `manifestSchemaVersion`: **4** (Build #6.38.1 — adds checklist, inspection visits and report layout on both platforms). Shipping baseline #6.37.1 uses v3. Candidate rows below are implemented on `codex/audit-reliability-improvements`, pending the coordinated database/server/web/iOS release in `server/RECOVERY.md`.

## Phase status

(Corrected in Build #6.18.1 — this section had lagged reality by four
phases. The feature rows below are the live truth; this list is the
historical phase ledger.)

- **Phase 0** — Parity machinery (✅ closed). Shared TS package, parity contract test, matrix doc, CLAUDE.md addendum, iOS `manifestSchemaVersion` field.
- **Phase 1** — Server foundation + auth + iOS↔server manifest sync (✅ closed). Supabase + Fastify on Render + React/Vite on Vercel + iOS auth/manifest push.
- **Phase 2** — Photos visible + editable on web (✅ closed — uploads #5.90.1, markup #5.91.1, trash/favorites/rotation/tags shipped through the Path P series #5.76.1–#5.83.1).
- **Phase 3** — Floor plans + distress on web (✅ closed — canvas + pins + distress CRUD, calibration-on-add #5.94.1).
- **Phase 4** — AI tagging + exports on web + project freeze (✅ closed at #5.126.1 — web AI runs/suggestions, PDF/folder/CSV exports, `isFrozen` tandem).
- **Phase 5** — Multi-user collaboration (✅ server+web: roles/admin #5.121.1–#5.125.1, edit lock #5.60.1 + self-lock fix #5.120.1, force-release gated #6.11.1. ✅ iOS advisory edit-lock UI shipped #6.21.1; candidate #6.38.1 enforces the session lock at server mutation boundaries while retaining offline local capture).

## Features

| Feature | iOS | Web | Shared schema | Notes |
|---|---|---|---|---|
| **Authentication** | | | | |
| Email + password sign in | ✅ Phase 1B-1 | ✅ Phase 1A | n/a (Supabase Auth handles user records) | Web shipped in PR #4; iOS in the Phase 1B-1 PR |
| Magic-link sign in | 📋 Phase 2 | 📋 Phase 2 | n/a | Defers until Resend is configured |
| **Project list & metadata** | | | | |
| List projects | ✅ | ✅ Phase 1A | server: `projects.manifest`, list endpoint at `GET /v1/projects` | iOS pushes manifests to server in Phase 1B-2; web reads them from `GET /v1/projects` |
| Create / rename project | ✅ | ✅ Build #5.84.1 | `Project.name` | "+ New project" modal on web list page; rename via Info-tab text input. Server `PUT /v1/projects/:id` already accepts create (expectedRevision: null) and update. iOS exposes create via `ProjectStore.create(named:)`; rename via swipe-leading "Rename" + alert TextField (Build #5.96.1). |
| Project GPS + address | ✅ | ✅ Build #5.83.1 | `Project.projectGPS`, `Project.projectAddress` | Address edit on Info tab (Path P #8/8); forward-geocoding to fill `projectGPS` stays iOS-only. |
| Start / stop / resume inspection visits | 🚧 #6.38.1 | 🚧 #6.38.1 | `Project.inspectionSessions[]`, legacy lifecycle fields | Matching explicit controls record distinct visits and retain earlier start/stop times. An open visit is not duplicated. |
| Soft-delete / restore project | ✅ | ✅ (Build #5.84.1) | `Project.isDeleted` (bool, default false), `POST /v1/projects/:id/restore` | iOS sets via `ProjectStore.delete(_:)`/`restore(_:)`. Web list filters trashed rows out of the active section and shows them in a collapsible "Trashed projects" section with a Restore button per row. Info tab's "Move to trash" sets `isDeleted=true` and navigates back to the list. |
| Permanently delete trashed project | ✅ (swipe) | ✅ Build #5.93.1 | `DELETE /v1/projects/:id` | New server endpoint reaps R2 blobs + `files` rows + project row in one shot; requires `isDeleted=true` first (409 otherwise — same two-step iOS swipe gesture). Web confirm dialog quotes the project name; iOS button is in the trashed-row swipe action. Candidate v4 authorizes and deletes database state before best-effort object cleanup, so a rejected deletion cannot remove evidence bytes. |
| Lock / finalize project (read-only) | ✅ UI; 🚧 enforcement #6.38.1 | ✅ UI; 🚧 enforcement #6.38.1 | `Project.isFrozen`, explicit server `isOwner` | Candidate server transactions reject ordinary edits/uploads while frozen, including mixed unlock-and-edit requests. Only owner/admin can toggle finalization; pure unlock has its own guarded save. Native account transitions clear cached grants, and an unknown-access project refreshes permissions even when its manifest revision is unchanged; late responses cannot restore an old account's grant (#6.38.4). Unconsumed upload receipts are revoked on freeze. |
| **Recovery and reusable workflows (candidate #6.38.1)** | | | | |
| Project health and safe retry | 🚧 | 🚧 | `ProjectHealthResponse`, exact asset filename resolver | iOS shows local files, pending saves/uploads and cloud availability with scoped retry/backfill. Web shows registry/object-store checks and missing names. Availability is not a backup or cryptographic verification receipt. |
| Protected version history and restore preview | 🚧 | 🚧 | Version snapshot and asset-reference endpoints | Preview metadata differences, then explicitly restore against the reviewed revision. Pending saves, changed previews, missing historical objects and frozen projects block restore. Legacy/incomplete versions remain reviewable only. |
| Cross-project search and saved filters | 🚧 | 🚧 | `SearchFilter`, caller-private `WorkflowLibrary` | SQL scopes results to permitted projects; caption/address/tag/date/favorite filters and bounded pagination. Saved filters use atomic revision checks. iOS cloud search requires a connection; it is not a new offline full-text index. |
| Inspection presets and checklists | 🚧 | 🚧 | `InspectionPreset`, `Project.inspectionChecklist[]` | Rename saved presets and edit their required views with revision checks; project application remains a separate previewed action. Preview appended buckets/checklist and replaced AI/report settings before applying. Preserves evidence, placement, captions and existing bucket assignments. Preset library is per-user; it does not replace the unsynced legacy iOS bucket-library editor. |
| Per-project report layout | 🚧 | 🚧 | `Project.reportLayout` | Density 1–12, bucket grouping and metadata-table defaults seed each client's PDF options; optional sections/annotation controls remain in the export dialog. |
| Shared bulk-tag vocabulary | 🚧 | ✅ | Existing `app_config.tagLibrary` | iOS bulk picker now reads the synced current library rather than bundled defaults. |
| Accessible dialogs and narrow layout | n/a (native sheets) | 🚧 | n/a | Shared modal handles initial focus, Tab containment, Escape and restoration for PDF/CSV/folder/bulk/restore/preset dialogs. Photo cards fit a 390-pixel viewport. This is not a full-app accessibility certification. |
| **Floor plans** | | | | |
| View floor plan (read-only) + pins + distress | ✅ | ✅ (#6.11.1 truth pass — shipped, row was stale) | `Project.floorPlans[]`, `Photo.planPixelX/Y`, `FloorPlan.distress[]` | Web canvas via react-konva (`FloorPlanCanvas.tsx` + `FloorPlanTab.tsx`); pins + distress rendered in plan-pixel coords (identical to iOS). Editing shipped too (see rows below). |
| Import floor plan (PDF / image) | ✅ | ✅ Build #5.90.1 / calibration #5.94.1 (image only) | `FloorPlan.imageFilename`, plus calibration / anchor / north fields | Web "+ Add plan" button → file picker → calibration sheet: pick origin + scale points A and B, type real-world distance, optional north heading + label. Pan + scroll-zoom + 2.5× magnifier loupe for pixel-precise placement. PDF import remains iOS-only (uses Apple PDFKit). |
| Calibrate plan (scale + origin + north) | ✅ | ✅ on add (#5.94.1) and re-calibrate (#6.39.1) | `FloorPlan.pixelsPerFoot`, `anchorPixelX/Y`, `anchorLocalXFeet/YFeet`, `northDeg` | Web calibration walks the user through origin → point A → point B → distance → north on upload. Recalibrate reuses the same sheet against the existing plan image. Pin/distress pixels stay put; `localXFeet/Y` re-derive from the new scale. |
| iPhone uploads plan image binary to R2 | ✅ Build #5.9.1 | n/a | n/a | PhotoSyncer extended to iterate `project.floorPlans` alongside photos; same iOS → R2 direct upload pattern. Plan binaries fill in the floor plan canvas backgrounds on web. |
| Calibrate scale (re-calibrate existing plan) | ✅ | ✅ Build #6.39.1 | `FloorPlan.pixelsPerFoot` | Manage plans → Recalibrate. Same origin/A/B/feet/north sheet as add. |
| Set north heading (existing plan) | ✅ | ✅ Build #6.39.1 | `FloorPlan.northDeg` | Same recalibrate sheet. |
| Multiple plans per project | ✅ | ✅ (#6.11.1 truth pass) | `Project.floorPlans[]`, `activeFloorPlanID` | Plan picker tabs on `/projects/:id/plan` |
| Rename / remove plans | ✅ | ✅ Build #5.89.1 | `FloorPlan.label`, `Project.floorPlans[]`, `Project.activeFloorPlanID` | Collapsible "Manage plans · N" disclosure above the picker chips; per-row label input (commit on blur), Set active, Remove (confirm + photo-impact preview; nulls `floorPlanID` + `planPixelX/Y` on photos that referenced the removed plan; falls back to the first remaining plan as active). Adding a brand-new plan ships with the file-upload PR. |
| **Photos** | | | | |
| Capture photo with camera | ✅ | ❌ | n/a | Web is desktop / tablet; capture is iOS-only |
| Import from photo library | ✅ | ✅ Build #5.90.1 | uses `POST /v1/projects/:id/files/upload-url` + commit | Web "+ Add photos" button on Photos tab — file picker (multi-select, `image/*`), 3-way concurrency, no client-side thumb generation (server falls back to `kind=photo` on thumb endpoint). Photos appended to manifest after all uploads finish. |
| Place photo on plan (drag) | ✅ | ✅ (#6.11.1 truth pass) | `Photo.planPixelX/Y`, `Photo.localXFeet/Y` | Pin drag + confirm in `FloorPlanTab.tsx`; same pixel coordinates both platforms |
| Re-locate photo | ✅ | ✅ (#6.11.1 truth pass) | same as above | |
| Soft-delete / restore photo | ✅ | ✅ (#6.11.1 truth pass) | `Project.trashedPhotos`, `Photo.trashedAt` | `TrashSection.tsx`: restore + delete-permanently + empty trash |
| Photo groups (primary + reshoots) | ✅ | ✅ (#6.11.1 truth pass) | `Photo.groupID`, `Photo.reshootsPhotoID` | `PhotoComparisonView.tsx` before/after carousel |
| Favorite photo | ✅ | ✅ (#6.11.1 truth pass) | `Photo.isFavorite` | Star toggle in `PhotoListRow.tsx` + favorites filter |
| Preview rotation (90° increments) | ✅ | ✅ (#6.11.1 truth pass) | `Photo.previewRotation` | Cycle button in `PhotoPreviewPanel.tsx` editor |
| **Tags & buckets** | | | | |
| Edit photo tags (manual) | ✅ | ✅ (#6.11.1 truth pass) | `Photo.tags[]` | Add/remove in `PhotoPreviewPanel.tsx` editor; same vocabulary both platforms |
| Hierarchical tags (primary / secondary) | ✅ | ✅ (#6.11.1 truth pass) | `Tag.parentTag` | Grouped by parent in the viewer + 3-level picker (#5.86.1) |
| Tag confidence threshold | ✅ | ✅ (#6.11.1 truth pass) | `Tag.confidence` | `useTagConfidenceThreshold` filters visible chips; per-user setting server-synced (#5.95.1) |
| Buckets (project-scoped categories) | ✅ | ✅ (Build #5.80.1, drag-reorder #5.87.1) | `Project.buckets[]`, `Photo.bucketID` | CRUD + ↑/↓ buttons shipped in Path P #5/8; HTML5 drag-and-drop reorder via per-row grip handle added separately. Renumbers `sortOrder` contiguously from 0 on drop. |
| Per-project tag selection | ✅ | ✅ Build #5.86.1 | `Project.tagSelection` | Three-column context → primary → secondary picker. Reads canonical library via `GET /v1/config/tagLibrary`; commit writes `tagSelection` through standard manifest PUT. Empty draft commits as `null` (means "use entire library"). |
| Per-project extra vocabulary | ✅ | ✅ (#6.11.1 truth pass; editor shipped #5.81.1) | `Project.aiExtraVocabulary` | JSON editor in `ProjectAIConfig.tsx` on the AI tab |
| **AI tagging** | | | | |
| Run AI analysis on photo | ✅ | ✅ (#6.11.1 truth pass) | request via server `/v1/ai/tag-photo` | Single-photo re-tag in `PhotoPreviewPanel.tsx` + batch via `useBatchRetag` / `BatchRetagControl`; same prompt template both platforms |
| Accept / reject tag suggestions | ✅ | ✅ (#6.11.1 truth pass) | `Photo.pendingSuggestions[]` | Per-chip accept/reject + bulk accept-all/reject-all in the viewer |
| AI prompt templates | ✅ (synced #6.3.1) | ✅ Build #5.104.1 | `app_config.aiPromptTemplates` (shared `AIPromptTemplateLibrary`) | Web admin editor at `/admin/ai-prompt-templates` (#5.104.1 — row was stale until #6.3.1). Build #6.3.1: iOS pulls at launch, pushes template add/rename/edit/delete (debounced, 409 → refetch-retry). iOS element struct mirrors shared `AIPromptTemplate` field-for-field. |
| AI rules templates | ✅ (synced #5.36.1) | ✅ (admin editor, PR #69) | `app_config.aiRulesTemplate` (shared `AIRulesTemplate`) | Row was doubly stale (#6.11.1 truth pass): iOS has synced this key since #5.36.1 and web's editor lives at `/admin/ai-rules`. |
| Recommended-use chip | ✅ | ✅ (#6.11.1 truth pass) | `AIPhotoAnalysis.recommendedUse` | Shown in the web viewer + "Use" filter in `PhotoFilterBar.tsx`; value is AI-authored on both platforms |
| Reviewer flag | ✅ | ✅ (#6.11.1 truth pass) | `AIPhotoAnalysis.reviewerFlag` | Shown in the web viewer + "Needs review" filter |
| **Distress annotations** | | | | |
| Place distress marker (point) | ✅ | ✅ (#6.11.1 truth pass) | `FloorPlan.distress[]` with `DistressKind` | Add point in `FloorPlanCanvas.tsx` |
| Draw floor-crack stroke | ✅ | ✅ (#6.11.1 truth pass) | `DistressMark.points[]` (stroke kind) | Stroke drawing on the web canvas |
| Annotate distress with note | ✅ | ✅ (#6.11.1 truth pass) | `DistressMark.note` | Edit kind/note + delete in `FloorPlanTab.tsx` |
| **Markup (PencilKit)** | | | | |
| Draw on photo with finger / Pencil | ✅ | ✅ Build #5.91.1 (Konva-based) | `Photo.markupOverlayFilename` | iOS uses PencilKit; web uses a Konva canvas in a modal — pen (color + width), eraser, undo / redo, clear. Rasterized to a transparent PNG at the photo's natural resolution on save. `markupDrawingFilename` (PencilKit stroke data) stays iOS-only — see Platform exclusions. |
| Render existing markup overlay | ✅ | ✅ Build #5.91.1 | `Photo.markupOverlayFilename` | Round-trippable: web saves the same PNG iOS does and vice versa. |
| **Export** | | | | |
| PDF export (authoritative, multi-floor) | ✅ | ✅ (#6.11.1 truth pass; shipped #5.62.1+) | n/a | iOS: `UIGraphicsPDFRenderer`; web: server-side Puppeteer via `ExportPdfControl.tsx` with iOS-parity options (page size, density, section order, annotations, bucket grouping) |
| Folder export (one dir per bucket) | ✅; 🚧 completeness #6.38.1 | ✅; 🚧 completeness #6.38.1 | Browser manifest and `project_exports` ZIP jobs | Candidate includes originals, plans and raw markup/drawing attachments. Native folders publish only after all required writes; server ZIPs verify streamed lengths; browser failures retain counts and require deliberate partial download. Native marked composites are additional derivatives; browser/server ZIPs retain the raw overlay for portable editing. |
| Report branding and logo transfer | ✅ text; 🚧 binary #6.38.1 | ✅; 🚧 dedicated logo route #6.38.1 | `app_config.reportBranding`; `/v1/branding/logo` | Candidate uses admin-only immutable logo uploads, then atomic config revision checks. iOS retains a pending local logo on conflict/failure and caches the matching shared binary; both PDF exporters require configured branding images to be available. No synthetic project/photo record is used for logos. |
| **Collaboration** | | | | |
| Project membership management | ❌ admin UI | ✅ | `profiles.is_admin`, `project_members` (database) | Membership administration remains web-only. Candidate iOS reads effective role/ownership and makes viewer projects read-only; server independently enforces access. |
| Checkout / edit lock | ✅ Build #6.21.1 (advisory) | ✅ (#5.60.1; self-lock fix #5.120.1) | `project_locks` (DB; not in the manifest) | Heartbeat-based, 10-min TTL; web `LockBanner` covers 7 states; force-release gated to Owner/Admin (#6.11.1). **iOS (#6.21.1) is deliberately advisory:** the workspace auto-acquires while open (so web sees "being edited on iPhone") and shows an amber holder banner when someone else holds it — but iOS editing is never blocked; the 3-way merge protects concurrent edits. Field capture can continue locally; candidate #6.38.1 queues a failed sync when the server lock belongs to another session and keeps that status visible. |
| Read-only membership role | 🚧 #6.38.1 | ✅ | Effective `ProjectRole` from manifest response | Viewer status disables local edits and server writes. It is separate from an advisory iOS edit-lock banner and from persistent project finalization. |
| Audit log | 📋 Phase 1 | 📋 Phase 1 | `audit_log` (server-side) | |
| **Settings** | | | | |
| Settings page | ✅ | ✅ Build #5.85.1 | n/a (UI shell) | `/settings` route with Account (email, password change, sign-out), AI tagging (model + threshold + concurrency), Team-wide config (links to /admin/tag-library and /admin/ai-rules), Diagnostics (build SHA / branch / timestamp). Gear-icon links in both the project list header and the workspace header. |
| Appearance (theme / accent) | ✅ | ❌ | `AppearanceSettings` | Web has one theme today (dark); per-user accent stays iOS-only — see Platform exclusions. |
| Plan color mode (status / bucket / primaryTag) | ✅ | ✅ Build #6.26.1; PDF #6.39.1 | per-user pref `user_prefs.planColorMode` (same rawValues as iOS's `PlanColorMode`) | Web: Color picker on the plan toolbar (Default / Bucket / Tag), cross-device synced via `useUserPrefs`. Bucket mode uses `colorHex` on both platforms. Primary-tag hues differ by design: iOS spaces by controlled-vocabulary rank, web hashes the label (no bundled vocab module) — same grouping, different palette. Server/web PDF now passes `PdfExportOptions.planColorMode` through shared `pinColorFor` so the office report matches the plan tab. iOS PDF already honored the mode. |
| Tag library management | ✅ | ✅ (PR #66) | `TagLibrary` (app-wide) | Tag library editor on `/admin/tag-library`; linked from settings page. |
| AI rules template management | ✅ | ✅ (PR #69) | `AIRulesTemplate` (app-wide) | AI rules editor on `/admin/ai-rules`; linked from settings page. |
| Tag confidence threshold (per-user) | ✅ | ✅ Build #5.85.1 (server-synced #5.95.1) | localStorage `sitephoto.tagConfidenceThreshold` + `user_prefs.tagConfidenceThreshold` | Same default + storage key as iOS. Threshold slider on settings page; same hook (`useUserPrefs`) drives both settings and the existing `useTagConfidenceThreshold` callers. Server sync follows prefs across browsers. |
| AI model / concurrency (per-user) | ✅ | ✅ Build #5.85.1 (server-synced #5.95.1) | localStorage `sitephoto.aiModel`, `sitephoto.aiConcurrency` + `user_prefs.{aiModel,aiConcurrency}` | localStorage instant-read + server sync (1-second debounce on writes; hydrate-on-mount). Defaults drive the Re-tag-all batch modal. |
| Floor-plan pin size (per-user) | n/a (iOS PDF only) | ✅ Build #6.13.1 | localStorage `sitephoto.planBubbleScale` + `user_prefs.planBubbleScale` | Cross-device sync of the FloorPlanTab `+ / −` pin-size buttons; shares the established `useUserPrefs` hydrate + debounced PUT pattern. iOS uses the same key for its PDF bubble size; the on-screen iOS plan viewer reads a different setting. **Build #6.20.1:** the web/server PDF exporter now honors it too (`PdfExportOptions.pinScale`) — previously web PDFs hardcoded pin size while iOS PDFs scaled, so the same project printed differently per platform. |

## Platform exclusions

These features are deliberately single-platform. Each must have a
one-line reason here; CI does not enforce parity for these rows.

- **Camera capture (iOS-only)** — web users are typically on
  desktops / tablets without a forensic-grade camera + lens setup.
  Web equivalent is "upload from disk".
- **48 MP capture + level overlay (iOS-only)** — Apple AVFoundation
  hardware features.
- **One-shot GPS capture (iOS-only)** — device location. Web does
  manual address entry only; forward-geocoding the typed string
  remains iOS-only.
- **Forward-geocoding the project address (iOS-only)** — uses Apple
  MapKit; web stores the literal string and iOS picks a fix on
  next sync if the user wants one.
- **PencilKit markup drawing (iOS-only)** — Apple PencilKit is iOS /
  iPadOS only. Web can display and edit a raster PNG overlay but cannot edit the original
  PencilKit stroke data. A new web overlay clears the stale PencilKit reference.
- **Voice dictation, alternate app icon, accent color (iOS-only)** —
  iOS UIKit / SwiftUI affordances with no web equivalent.

## Path P (web ↔ iOS parity series) — closed 2026-06-08

The Path P series (PRs #110–#117, Builds #5.76.1 → #5.83.1) closed
the per-project workflow gap between iOS and web. As of Build
#5.83.1 the web Forensic project workspace has parity with iOS
for everything except hardware-bound captures and PencilKit; the
list below mirrors the eight PRs in order:

- **#1 (#5.76.1):** Tabbed `ProjectWorkspacePage` shell + shared
  `useProjectManifest` hook. Six tabs: Photos / Floor Plan / AI /
  Buckets / Export / Info. Single manifest + single edit lock
  shared across all tabs.
- **#2 (#5.77.1):** Rich photo list rows — thumbnail + #N + group
  glyph + AI-pending / Review / Measurement badges + timestamp +
  location label + bucket dot + caption preview + tag chips +
  action stack. Responsive `auto-fill, minmax(380px, 1fr)` grid.
- **#3 (#5.78.1):** Filter chip bar — plan / placed / date / bucket
  (OR) / tag (AND, threshold-aware) / favorites / needs-review /
  has-measurement / recommended-use (OR) / search. Header reads
  "Photos · N · M shown".
- **#4 (#5.79.1):** Per-photo editor — caption, observation, bucket,
  rotation, favorite, and direct tag chip add/remove. Inline inside
  `PhotoPreviewPanel` so floor-plan and Photos-tab share the same
  editor surface.
- **#5 (#5.80.1):** Bucket CRUD — create / rename / recolor / reorder
  (↑/↓ swap `sortOrder`) / delete (with affected-photo confirm).
- **#6 (#5.81.1):** Project AI config — AI notes (`aiInstructions`),
  job vocabulary (`aiExtraVocabulary.primaries` JSON editor), tag-
  selection summary, "Clear AI tags" (± analysis) project-wide.
- **#7 (#5.82.1):** Select mode + batch actions — Move to bucket,
  Move to level, Apply tag, Delete (soft-delete to trash). Select
  toggle gated on edit lock; Select all selects only the currently-
  filtered subset.
- **#8 (#5.83.1):** Trash management (Restore / Delete permanently /
  Empty trash) on the Photos tab + editable `projectAddress` on
  the Info tab.

Follow-ons still tracked (Phase 4+):

- ~~**Full 3-level tag-selection picker UI on web.**~~ — shipped Build #5.86.1.
- ~~**Re-tag-with-AI on a selection.**~~ — shipped Build #5.88.1. `useBatchRetag.start()` accepts an optional `photoIds` filter; the Photos-tab `SelectionActionBar` exposes a "Re-tag with AI" button that mounts a transient `BatchRetagControl` scoped to the snapshot of `selectedIds`.
- ~~**Web file-upload "add photos".**~~ — shipped Build #5.90.1. Photos tab "+ Add photos" + Floor Plan tab "+ Add plan", both via existing presigned-PUT endpoints.
- ~~**Web canvas markup drawing.**~~ — shipped Build #5.91.1 via Konva. The PencilKit stroke data side (`markupDrawingFilename`) stays iOS-only.
- ~~**Report branding.**~~ — shipped Build #5.92.1. New `app_config.reportBranding` key + admin editor at `/admin/report-branding`. iOS-side sync shipped in Build #6.2.1 (text two-way; logo binary follow-on).
- ~~**Drag-and-drop bucket reorder.**~~ — shipped Build #5.87.1.

## Update procedure

For every PR that adds, removes, or changes a feature:

1. Locate the row(s) in the table above that match your change.
2. Update the iOS column **and** the Web column to reflect what the PR
   actually does. If the PR only touches one platform, file a follow-up
   issue with the corresponding subtask on the other platform and link
   it in the PR description.
3. If you added a new field to a model, add the field name to the
   "Shared schema" column of the relevant row.
4. If you bumped `manifestSchemaVersion`, update the value at the top
   of this file.
5. If the feature is genuinely platform-exclusive, move it to "Platform
   exclusions" with a one-line reason.
6. The PR template checkbox is your reminder that this file needs
   touching. CI's parity contract test catches schema-level drift but
   does **not** catch a missing matrix update — that's on the author.
