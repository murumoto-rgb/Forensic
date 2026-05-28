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

Current `manifestSchemaVersion`: **1**

## Features

| Feature | iOS | Web | Shared schema | Notes |
|---|---|---|---|---|
| **Authentication** | | | | |
| Email + password sign in | ✅ Phase 1B-1 | ✅ Phase 1A | n/a (Supabase Auth handles user records) | Web shipped in PR #4; iOS in the Phase 1B-1 PR |
| Magic-link sign in | 📋 Phase 2 | 📋 Phase 2 | n/a | Defers until Resend is configured |
| **Project list & metadata** | | | | |
| List projects | ✅ | ✅ Phase 1A | server: `projects.manifest`, list endpoint at `GET /v1/projects` | iOS pushes manifests to server in Phase 1B-2; web reads them from `GET /v1/projects` |
| Create / rename project | ✅ | 📋 Phase 2 | `Project.name` | |
| Project GPS + address | ✅ | 📋 Phase 2 | `Project.projectGPS`, `Project.projectAddress` | |
| Start / stop project | ✅ | 📋 Phase 2 | `Project.startedAt`, `Project.stopped` | |
| Soft-delete / restore project | ✅ | 📋 Phase 2 | n/a (file-level) | |
| **Floor plans** | | | | |
| Import floor plan (PDF / image) | ✅ | 📋 Phase 2 | `FloorPlan.imageFilename` | |
| Calibrate scale | ✅ | 📋 Phase 3 | `FloorPlan.pixelsPerFoot` | |
| Set north heading | ✅ | 📋 Phase 3 | `FloorPlan.northDeg` | |
| Multiple plans per project | ✅ | 📋 Phase 3 | `Project.floorPlans[]`, `activeFloorPlanID` | |
| Reorder / rename plans | ✅ | 📋 Phase 3 | `FloorPlan.label` | |
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
| Appearance (theme / accent) | ✅ | 📋 Phase 2 | `AppearanceSettings` | |
| Plan color mode (mono / colour) | ✅ | 📋 Phase 2 | `PlanColorMode` | |
| Tag library management | ✅ | 📋 Phase 4 | `TagLibrary` (app-wide) | |

## Platform exclusions

These features are deliberately single-platform. Each must have a
one-line reason here; CI does not enforce parity for these rows.

- **Camera capture (iOS-only)** — web users are typically on
  desktops / tablets without a forensic-grade camera + lens setup.
  Web equivalent is "upload from disk".
- **PencilKit markup drawing (iOS-only)** — Apple PencilKit is iOS /
  iPadOS only. Web shows existing markup as a read-only PNG overlay
  on top of the photo.

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
