# Forensic repository agent guidance

Shared rules apply to all coding agents. Use task-relevant references instead of
loading the entire app/release workflow for every edit.

## Scope and references

- For manifest models, tags, schema changes, or user-visible features, follow
  `docs/PARITY_AGENT_GUIDE.md` and the affected `docs/parity-matrix.md` rows.
  Preserve the existing tandem-PR, schema-version and phase-sign-off requirements.
- For app development, iOS device testing or release handoff, read the relevant
  sections of `docs/IOS_AGENT_WORKFLOW.md`. App branches retain the owner testing
  and selective-merge workflow; a merge is not TestFlight delivery. Only the owner
  initiates a TestFlight build or release tag.
- Use the relevant README/setup guide for the surface being changed. Load skills
  only for their specific workflow. Work directly for clear tasks; delegate bounded
  investigations only when they materially improve the result.

## Validation and completion

Run the applicable automated checks before pushing. Inspect the full PR diff,
changed call sites and affected data flows. Preserve old Codable saves with defaults
for new fields. Toolchain availability depends on the host; simulator checks do not
prove physical iPhone behavior.

For user-visible iOS changes, provide a device checklist with one concrete action
and observable result per item, plus affected regression flows. Carry forward any
physical-device verification that automation cannot establish. Record focused test
results and limits in the PR; do not require separate repetitive self-test comments
or device checklists for changes with no device surface.

Resolve routine choices and failures caused by the requested change. After affected
checks pass, broaden or repeat only for a new change, failure or unresolved risk.
If blocked, state the exact blocker and smallest owner action needed.

A documentation-only PR is complete when references, current-source claims and the
diff are checked, it is mergeable, and applicable required checks pass. This narrow
exception applies only when no runtime, configuration, schema, manifest, build or
release-automation behavior changes. Open and merge that PR without device testing,
app build/version edits, iOS sync instructions, or TestFlight actions. Preserve
unrelated local work and use a task branch from freshly fetched `origin/main`.

## Repository contracts

- Monorepo with three code stacks:
  - `ios/` — SwiftUI iOS app (Xcode-generated via `xcodegen`
    from `ios/project.yml`).
  - `server/` — Fastify + TypeScript API (Render-hosted).
  - `web/` — React + Vite SPA (Vercel-hosted).
  - `packages/shared/` — TypeScript types + zod schemas; the
    **canonical schema** that both server and web consume,
    and that iOS Codable structs mirror field-for-field.
- `Info.plist` and `SitePhoto.entitlements` are **xcodegen
  artifacts**, not source files. Source of truth is the inline
  `info.properties` and `entitlements.properties` blocks in
  `ios/project.yml`. Both files are gitignored; running
  `xcodegen generate` rewrites them. Never edit either file
  directly — edit `project.yml` and regenerate.
- **`ios/SitePhoto/Generated/BuildInfo.swift`** is auto-generated
  by `ios/scripts/gen-build-info.sh` and gitignored. It holds the
  git SHA + branch + UTC timestamp that the in-app "About"
  section displays. To regenerate it, run
  `ios/scripts/regen-project.sh` instead of `xcodegen generate`
  directly — the wrapper runs `gen-build-info.sh` first, then
  `xcodegen generate`. This is the standard "regenerate the
  project" entry point now.
- App models persist via `Codable` JSON on disk; older saves
  must remain decodable when fields are added — always default
  new fields and run focused backward-compatibility checks for the affected saved data.
- PDF export lives in `PDFExportService.swift` (iOS) and uses
  a two-phase `countPages` / render-loop pattern. Any change
  to pagination must update both phases together; the
  data-flow-tracing step must walk both phases for every
  export mode.
