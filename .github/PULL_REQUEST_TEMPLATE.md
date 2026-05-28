## Summary

<!-- 1–3 bullets on what this PR does and why. -->

## Platforms touched

- [ ] iOS (`ios/`)
- [ ] Web (`web/`)
- [ ] Server (`server/`)
- [ ] Shared schema (`packages/shared/`)

## Parity checklist

If this PR changes a manifest model, a tag, or any user-visible
feature listed in `docs/parity-matrix.md`:

- [ ] Updated `docs/parity-matrix.md` (the row(s) this touches)
- [ ] Updated TS types in `packages/shared/src/manifest.ts`
- [ ] Updated zod schema in `packages/shared/src/validation.ts`
- [ ] Updated matching iOS Swift Codable struct(s)
- [ ] Regenerated `packages/shared/fixtures/ios-models.json` via
      `pnpm parity:regen-fixtures`
- [ ] Bumped `manifestSchemaVersion` if semantics changed
- [ ] CI parity contract test is green

If this PR is **iOS-only** or **web-only** by design, state the
reason here and confirm the matrix row reflects it:

> Reason for single-platform PR: …

## Test plan

<!-- Bulleted checklist of what you tested. Per CLAUDE.md, an
     iPhone device verification checklist will be posted as a PR
     comment after push. -->

- [ ]
