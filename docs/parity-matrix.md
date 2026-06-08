# iOS ↔ Web Parity Matrix

This file is the **living source of truth** for which features exist on
which platform. It must be updated in the **same PR** that changes a
feature's behaviour on either platform. The GitHub PR template asks for
this explicitly; CI's parity contract test (see `packages/shared/`)
enforces schema-level parity at build time.

## Legend

- ✅ Implemented and shipping
- 🚧 In progress (link the PR)
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

Current `manifestSchemaVersion`: **2** (bumped in Build #5.6.1 — added `Project.isDeleted: boolean`)

## Phase status

- **Phase 0** — Parity machinery (✅ closed). Shared TS package, parity contract test, matrix doc, CLAUDE.md addendum, iOS `manifestSchemaVersion` field.
- **Phase 1** — Server foundation + auth + iOS↔server manifest sync (✅ closed). Supabase project + DB schema, Fastify server on Render, React+Vite web app on Vercel, iOS Supabase Auth + manifest push. End-to-end verified: saving a project on iPhone makes it appear in the web project list within seconds.
- **Phase 2** — Photos visible on web (📋 planned). Photo file upload to Supabase Storage, web photo viewer.
- **Phase 3** — Floor plans + distress visible on web (📋 planned).
- **Phase 4** — AI tagging + PDF export on web (📋 planned).
- **Phase 5** — Multi-user collaboration + edit-lock (📋 planned).

## Features

| Feature | iOS | Web | Shared schema | Notes |
|---|---|---|---|---|
| **Authentication** | | | | |
| Email + password sign in | ✅ Phase 1B-1 | ✅ Phase 1A | n/a (Supabase Auth handles user records) | Web shipped in PR #4; iOS in the Phase 1B-1 PR |
| Magic-link sign in | 📋 Phase 2 | 📋 Phase 2 | n/a | Defers until Resend is configured |
| **Project list & metadata** | | | | |
| List projects | ✅ | ✅ Phase 1A | server: `projects.manifest`, list endpoint at `GET /v1/projects` | iOS pushes manifests to server in Phase 1B-2; web reads them from `GET /v1/projects` |
| Create / rename project | ✅ | ✅ Build #5.84.1 | `Project.name` | "+ New project" modal on web list page; rename via Info-tab text input. Server `PUT /v1/projects/:id` already accepts create (expectedRevision: null) and update. iOS exposes create via `ProjectStore.create(named:)`; rename is iOS-only follow-on (the Info screen there is read-only for the name today). |
| Project GPS + address | ✅ | ✅ Build #5.83.1 | `Project.projectGPS`, `Project.projectAddress` | Address edit on Info tab (Path P #8/8); forward-geocoding to fill `projectGPS` stays iOS-only. |
| Start / stop project | ✅ | 📋 Phase 2 | `Project.startedAt`, `Project.stopped` | |
| Soft-delete / restore project | ✅ | ✅ (Build #5.84.1) | `Project.isDeleted` (bool, default false), `POST /v1/projects/:id/restore` | iOS sets via `ProjectStore.delete(_:)`/`restore(_:)`. Web list filters trashed rows out of the active section and shows them in a collapsible "Trashed projects" section with a Restore button per row. Info tab's "Move to trash" sets `isDeleted=true` and navigates back to the list. Permanent deletion still pending — server endpoint not yet built. |
| **Floor plans** | | | | |
| View floor plan (read-only) + pins + distress | ✅ | 🚧 Phase 3 PR-A (#34) | `Project.floorPlans[]`, `Photo.planPixelX/Y`, `FloorPlan.distress[]` | Web canvas via react-konva; pins + distress rendered in plan-pixel coords (identical to iOS). Plan image fetched via `GET /v1/projects/:id/plans/:planId/image`; 404 = "pending upload from iPhone" placeholder. Editing lands in PR-B. |
| Import floor plan (PDF / image) | ✅ | 📋 Phase 3 PR-C | `FloorPlan.imageFilename` | |
| iPhone uploads plan image binary to R2 | ✅ Build #5.9.1 | n/a | n/a | PhotoSyncer extended to iterate `project.floorPlans` alongside photos; same iOS → R2 direct upload pattern. Plan binaries fill in the floor plan canvas backgrounds on web. |
| Calibrate scale | ✅ | 📋 Phase 3 PR-C | `FloorPlan.pixelsPerFoot` | |
| Set north heading | ✅ | 📋 Phase 3 PR-C | `FloorPlan.northDeg` | |
| Multiple plans per project | ✅ | 🚧 Phase 3 PR-A (#34) | `Project.floorPlans[]`, `activeFloorPlanID` | Plan picker tabs on `/projects/:id/plan` |
| Reorder / rename plans | ✅ | 📋 Phase 3 PR-C | `FloorPlan.label` | |
| **Photos** | | | | |
| Capture photo with camera | ✅ | ❌ | n/a | Web is desktop / tablet; capture is iOS-only |
| Import from photo library | ✅ | 📋 Phase 2 | n/a | Web equivalent: upload from disk |
| Place photo on plan (drag) | ✅ | 📋 Phase 3 | `Photo.planPixelX/Y`, `Photo.localXFeet/Y` | Same pixel coordinates both platforms |
| Re-locate photo | ✅ | 📋 Phase 3 | same as above | |
| Soft-delete / restore photo | ✅ | 📋 Phase 2 | `Project.trashedPhotos`, `Photo.trashedAt` | |
| Photo groups (primary + reshoots) | ✅ | 📋 Phase 3 | `Photo.groupID`, `Photo.reshootsPhotoID` | |
| Favorite photo | ✅ | 📋 Phase 2 | `Photo.isFavorite` | |
| Preview rotation (90° increments) | ✅ | 📋 Phase 2 | `Photo.previewRotation` | |
| **Tags & buckets** | | | | |
| Edit photo tags (manual) | ✅ | 📋 Phase 2 | `Photo.tags[]` | Same vocabulary both platforms |
| Hierarchical tags (primary / secondary) | ✅ | 📋 Phase 2 | `Tag.parentTag` | |
| Tag confidence threshold | ✅ | 📋 Phase 2 | `Tag.confidence` | |
| Buckets (project-scoped categories) | ✅ | 📋 Phase 2 | `Project.buckets[]`, `Photo.bucketID` | |
| Per-project tag selection | ✅ | 📋 Phase 4 | `Project.tagSelection` | |
| Per-project extra vocabulary | ✅ | 📋 Phase 4 | `Project.aiExtraVocabulary` | |
| **AI tagging** | | | | |
| Run AI analysis on photo | ✅ | 📋 Phase 4 | request via server `/v1/ai/tag-photo` | Same prompt template both platforms |
| Accept / reject tag suggestions | ✅ | 📋 Phase 4 | `Photo.pendingSuggestions[]` | |
| AI prompt templates | ✅ | 📋 Phase 4 | `AIPromptTemplate` | Local-only today; sync in Phase 4 |
| AI rules templates | ✅ | 📋 Phase 4 | `AIRulesTemplate` | Local-only today; sync in Phase 4 |
| Recommended-use chip | ✅ | 📋 Phase 4 | `AIPhotoAnalysis.recommendedUse` | |
| Reviewer flag | ✅ | 📋 Phase 4 | `AIPhotoAnalysis.reviewerFlag` | |
| **Distress annotations** | | | | |
| Place distress marker (point) | ✅ | 📋 Phase 3 | `FloorPlan.distress[]` with `DistressKind` | |
| Draw floor-crack stroke | ✅ | 📋 Phase 3 | `DistressMark.points[]` (stroke kind) | |
| Annotate distress with note | ✅ | 📋 Phase 3 | `DistressMark.note` | |
| **Markup (PencilKit)** | | | | |
| Draw on photo with finger / Pencil | ✅ | ❌ | `Photo.markupOverlayFilename`, `markupDrawingFilename` | iOS-only (PencilKit); web shows PNG overlay read-only |
| Render existing markup overlay | ✅ | 📋 Phase 2 | same | Web read-only display of the PNG |
| **Export** | | | | |
| PDF export (authoritative, multi-floor) | ✅ | 📋 Phase 4 | n/a | iOS: `UIGraphicsPDFRenderer`; web: server-side Puppeteer (preview-grade) |
| Folder export (one dir per bucket) | ✅ | 📋 Phase 4 | n/a | |
| Report branding | ✅ | 📋 Phase 4 | `ReportBranding` | |
| **Collaboration** | | | | |
| Multi-user project access | 📋 Phase 1 | 📋 Phase 1 | `manifest.access[]` | Supabase RLS |
| Checkout / edit lock | 📋 Phase 5 | 📋 Phase 5 | `manifest.lock` | Heartbeat-based, 10-min timeout |
| Read-only viewer (no lock) | 📋 Phase 5 | 📋 Phase 5 | same | |
| Audit log | 📋 Phase 1 | 📋 Phase 1 | `audit_log` (server-side) | |
| **Settings** | | | | |
| Settings page | ✅ | ✅ Build #5.85.1 | n/a (UI shell) | `/settings` route with Account (email, password change, sign-out), AI tagging (model + threshold + concurrency), Team-wide config (links to /admin/tag-library and /admin/ai-rules), Diagnostics (build SHA / branch / timestamp). Gear-icon links in both the project list header and the workspace header. |
| Appearance (theme / accent) | ✅ | ❌ | `AppearanceSettings` | Web has one theme today (dark); per-user accent stays iOS-only — see Platform exclusions. |
| Plan color mode (mono / colour) | ✅ | 📋 Phase 2 | `PlanColorMode` | |
| Tag library management | ✅ | ✅ (PR #66) | `TagLibrary` (app-wide) | Tag library editor on `/admin/tag-library`; linked from settings page. |
| AI rules template management | ✅ | ✅ (PR #69) | `AIRulesTemplate` (app-wide) | AI rules editor on `/admin/ai-rules`; linked from settings page. |
| Tag confidence threshold (per-user) | ✅ | ✅ Build #5.85.1 | localStorage `sitephoto.tagConfidenceThreshold` | Same default + storage key as iOS. Threshold slider on settings page; same hook (`useUserPrefs`) drives both settings and the existing `useTagConfidenceThreshold` callers. |
| AI model / concurrency (per-user) | ✅ | ✅ Build #5.85.1 | localStorage `sitephoto.aiModel`, `sitephoto.aiConcurrency` | localStorage today; server-backed multi-device sync planned. Defaults drive the Re-tag-all batch modal. |

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
  iPadOS only. Web shows existing markup as a read-only PNG overlay
  on top of the photo.
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

- **Full 3-level tag-selection picker UI on web.** Today web honors
  whatever iOS set; the picker UI itself lands later.
- **Re-tag-with-AI on a selection.** `useBatchRetag` doesn't accept
  a photoIds filter yet; the AI tab's "skip-already-tagged" covers
  the most-common "untagged only" workflow today.
- **Web file-upload "add photos".** Optional — feasible via the
  existing presigned-PUT endpoints; not in Path P scope.
- **Web canvas markup drawing.** A non-PencilKit equivalent is a
  separate, large effort.
- **Report branding.** Logos / colors / header-text payload lives in
  `app_config`; the upload + edit UI is its own PR.
- **Drag-and-drop bucket reorder.** Today web uses ↑/↓ arrows
  matching the iOS UX.

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
