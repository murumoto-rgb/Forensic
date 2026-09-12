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
