# Project notes for future Claude sessions

## Post-push testing regime

This project has no test target, no `*Tests.swift` files, no CI
workflow, and the sandbox has no Swift toolchain. "Testing" in this
repo therefore means a deliberate two-part process that runs after
**every** `git push`:

1. **Static self-test** by Claude (no device required).
2. **Device verification checklist** for the human, who runs the
   app on an iPhone.

### Trigger

After **any** `git push` that lands code on a branch with an open
PR — or for which a PR is opened in the same turn — do all of the
following, in order, before stopping:

1. Run the self-test rubric (below) against the diff since the
   PR's base branch, not just the latest commit.
2. Post the self-test report as a PR comment titled
   `### Self-test report — <short-sha>` (use the short SHA of the
   HEAD commit being reviewed).
3. Generate a verification checklist using the template (below),
   scoped to the user-visible behaviour introduced or changed by
   this push, and post it as a PR comment titled
   `### Device verification checklist — <short-sha>`.
4. If no PR exists for the branch, ask the user whether to open
   one or skip the regime for that push.
5. After posting both comments, stop. Do not push further changes
   until PR activity or user direction warrants it.

### Self-test rubric

Each push's report walks these categories. Items not applicable
to a given diff are skipped with a one-line "n/a" justification
rather than silently dropped — that way the user can see at a
glance that the category was considered.

1. **File-level re-read.** Re-read every file in the diff. Look
   for syntax issues, missing imports, dead code, unused
   parameters, accidental whitespace-only edits.
2. **API + signature spot-checks.** For any new SDK / framework
   surface (especially version-gated iOS APIs), confirm the API
   exists with the assumed signature and availability.
3. **Cross-file consistency.** For each new or renamed
   identifier, grep call sites and confirm the diff updates all
   of them. For each new closure parameter on a view, confirm
   declaration and call site agree.
4. **Data-flow tracing.** Pick the 3–5 trickiest paths the diff
   introduces and trace them end to end (input → state mutation
   → render / persistence / export).
5. **Regression sanity.** Default values, persisted-blob
   compatibility: anything decoded from older saves must still
   decode without the new fields. Anything a user on the old
   code path never opted into must behave exactly as before.
6. **Lint-equivalent eyeballing.** Force-unwraps, force-tries,
   silently swallowed errors, retain cycles in closures captured
   by view state.
7. **Parity check.** For every push that touches a manifest
   model (Project, Photo, FloorPlan, DistressMark, Bucket, Tag,
   TagSuggestion, AIPhotoAnalysis, ProjectGPS, or any field
   referenced by `docs/parity-matrix.md`):
   - Was the change made on **both** sides — the iOS Swift
     struct AND `packages/shared/src/manifest.ts` (with its
     zod schema in `validation.ts`)? Or, if web-side work
     isn't ready yet, is the matrix updated to reflect that
     web is still 📋 Planned for this feature?
   - Was `packages/shared/fixtures/ios-models.json`
     regenerated via `pnpm parity:regen-fixtures`?
   - Did `docs/parity-matrix.md` get touched if the diff
     changes a row in the table?
   - Did `manifestSchemaVersion` need bumping (added /
     removed / renamed field; changed semantics)? If so, was
     it bumped in iOS Project.swift, in shared, and in the
     matrix header in one PR?
   Skip with a one-line "n/a — no manifest model touched"
   when none of the above applies.

### Device verification checklist template

```
### Device verification checklist — <short-sha>

Scope: <one sentence summary of what this push changes from a
user's POV>.

#### <Feature / area 1>
- [ ] <observable user action> → <expected observable result>
- [ ] ...

#### <Feature / area 2>
- [ ] ...

#### Regression spot-checks
- [ ] <pre-existing flow that touches code paths the push
      modified> still behaves identically.
```

Rules:

- Every item is a **single user action** with a **single
  observable outcome**. Avoid "verify that X works".
- Items must reference things visible on the device — never log
  lines, internal state, file contents, or DB rows.
- Each push gets a **fresh checklist scoped to that push's
  diff**. Do not re-paste items the previous push already
  covered, unless the current diff plausibly regresses them — in
  which case they go under **Regression spot-checks**.

### Notes on this repo

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
  new fields and verify via the regression-sanity step above.
- PDF export lives in `PDFExportService.swift` (iOS) and uses
  a two-phase `countPages` / render-loop pattern. Any change
  to pagination must update both phases together; the
  data-flow-tracing step must walk both phases for every
  export mode.

## Web/iOS parity is mandatory

The single highest-risk failure mode for this project is iOS and
web drifting apart — different field shapes, different tag
vocabularies, different semantics for the same setting. Several
overlapping mechanisms enforce parity; **do not skip any of them**
when changing a manifest model or a user-visible feature.

### The contract

- `packages/shared/src/manifest.ts` is the **canonical schema**.
  TypeScript types in here describe every field of every model
  that lives in a manifest (Project, Photo, FloorPlan,
  DistressMark, Bucket, Tag, TagSuggestion, AIPhotoAnalysis,
  ProjectGPS, the enums) plus their server-side wire shapes.
- `packages/shared/src/validation.ts` carries zod schemas that
  validate manifests at the server boundary.
- iOS Swift Codable structs in `ios/SitePhoto/Models/` **mirror**
  the shared TS types. They are not generated from them — but
  they must agree, field-for-field.
- The parity contract test in
  `packages/shared/tests/ios-parity.test.ts` compares a checked-in
  snapshot of iOS struct shapes (`packages/shared/fixtures/ios-models.json`)
  against the TS types. CI runs it on every PR.

### The "tandem PR" rule

Every PR that adds or changes user-visible behaviour takes one of
three legal shapes:

1. **Tandem PR (default).** Touches iOS + shared + (eventually)
   web in one PR. The matrix row for the feature shows the same
   status on both platforms.
2. **iOS-only PR.** Allowed only when the change is genuinely
   iOS-specific (camera capture, PencilKit, hardware sensors,
   iCloud). The PR description states the reason and the matrix
   row goes under "Platform exclusions" with a one-line
   justification.
3. **Web-only PR.** Allowed for server-side / web-admin work that
   has no iOS surface (server observability, admin tooling).
   Same matrix discipline as iOS-only.

A PR that adds a new field to any manifest model touches **all
three** of: iOS Swift struct, shared TS types, shared zod schema.
No exceptions during Phases 0–4 (the parity-closing phases).

### When adding / changing a field

1. Add the field to `packages/shared/src/manifest.ts` first.
2. Add it to the zod schema in `packages/shared/src/validation.ts`.
3. Add it to the iOS Codable struct (with a sensible default and
   `decodeIfPresent` so old manifests still decode — see existing
   `Project.init(from:)` for the pattern).
4. Run `pnpm parity:regen-fixtures` to refresh
   `packages/shared/fixtures/ios-models.json`.
5. Run `pnpm parity` locally to confirm the contract test passes.
6. Update `docs/parity-matrix.md` — at minimum the "Shared
   schema" column; bump `manifestSchemaVersion` if semantics
   changed.
7. Land it in one PR.

### Schema versioning

`Project.manifestSchemaVersion` carries the integer schema version.
The server rejects writes whose version exceeds what it knows
about (forces the server to be updated first) and warns clients on
older versions. Every bump lands in iOS + shared + server in one
PR.

### Phase-gate parity sign-off

The closing PR of each phase (0–5) includes an explicit "Parity
sign-off" comment listing: shared-schema fields added, iOS struct
changes, web UI added, matrix rows touched, and the parity
contract test result on the merge commit.

## Session conventions

Durable rules for how Claude operates in this repo, captured so
they survive across sessions instead of being re-explained each
time. Authorized by the user in chat on 2026-05-30.

### Local repo path on the user's Mac

The user keeps the working clone at `~/Developer/Forensic`. Every
pull/build one-liner included in a chat reply must start with
`cd ~/Developer/Forensic && …` — do not guess `~/Code/Forensic`,
`~/Projects/Forensic`, or any other path. If the user moves the
clone, the new path lands here in a follow-up PR.

### Auto-subscribe to PR activity

For **every** PR opened in a session, call
`subscribe_pr_activity` for that PR before ending the turn —
without waiting for the user to ask. Subscribing means Claude
auto-reacts to CI failures and review comments without the user
having to flag them. This is a standing rule; the user does not
need to repeat the request per PR.

### Every chat response

Three things appear in every response that involves work on the
repo (not pure Q&A):

1. **Lead with the build annotation** — `Build #N.M.P (new)`
   when the response is about to push a commit creating that
   build, or `Build #N.M.P (active)` when no push is happening
   but the response references the latest build.
2. **Include the pull + build terminal one-liner** when a PR is
   pushed in the turn, so the user can paste it straight into
   Terminal:
   ```
   cd ~/Developer/Forensic && git fetch origin && \
     git checkout <branch> && git pull && \
     ./ios/scripts/regen-project.sh && open ios/SitePhoto.xcodeproj
   ```
   (or, once PR #27 ships, `./scripts/sync-ios.sh <branch>`.)
3. **Direct GitHub comment URL** for every checklist or self-test
   report posted in the turn — link to the specific comment
   (`#issuecomment-<id>`), not just the PR.
