# Forensic (SitePhoto)

Construction-site photo documentation for forensic engineering:
capture on iPhone in the field, review/annotate/export from the
desk on the web, with AI-assisted tagging throughout.

## Monorepo layout

| Directory | What it is | Where it runs |
|---|---|---|
| [`ios/`](ios/) | SwiftUI iPhone app (capture, floor plans, markup, PDF export). Xcode project generated via `xcodegen` from `ios/project.yml`. | TestFlight (manual trigger) |
| [`web/`](web/) | React + Vite SPA (review workspace, admin pages, exports). | Vercel (auto-deploy on `main`) |
| [`server/`](server/) | Fastify + TypeScript API (manifests, presigned R2 uploads, AI proxy, PDF/ZIP/CSV export workers). | Render (auto-deploy on `main`) |
| [`packages/shared/`](packages/shared/) | **Canonical schema**: TypeScript types + zod validators that server and web consume and that iOS Codable structs mirror field-for-field. | n/a (library) |
| [`supabase/migrations/`](supabase/migrations/) | Postgres schema (Supabase). | Supabase |
| [`docs/`](docs/) | Build registry, parity matrix, deferred-work backlog. | n/a |

Backing services: **Supabase** (Postgres + Auth), **Cloudflare R2**
(photo/plan binaries — clients upload directly via presigned URLs),
**Anthropic** (AI tagging).

## The one rule that matters

**iOS and web must not drift.** `packages/shared/src/manifest.ts` is
the canonical manifest schema; iOS structs mirror it; a CI contract
test (`packages/shared/tests/ios-parity.test.ts`) fails any PR that
changes one side without the other. [`docs/parity-matrix.md`](docs/parity-matrix.md)
is the living feature-by-feature ledger. See `CLAUDE.md` for the full
tandem-PR rules.

## Quick start

Each sub-project has its own README with setup details:
[`ios/README.md`](ios/README.md) · [`web/README.md`](web/README.md) ·
[`server/README.md`](server/README.md)

```bash
pnpm install                  # workspace deps (web, server, shared)
pnpm parity                   # run the iOS↔TS parity contract test
cd web && pnpm dev            # web app against the live server
cd server && pnpm dev         # API locally (needs .env)
scripts/sync-ios.sh main      # pull + regen + open the Xcode project
```

## Build numbering

Every PR gets a build doc in [`docs/builds/`](docs/builds/) named
`MAJOR.BRANCH.PUSH.md`; the version-sorted max is the build number
shown in the iOS About screen and the web footer. Conventions in
[`docs/builds.md`](docs/builds.md).

## Deployment

- **Web/server:** merging to `main` deploys (Vercel + Render). No
  extra step.
- **iOS:** merging does *not* ship. TestFlight builds are triggered
  manually — App Store Connect → Xcode Cloud → Start Build, or
  `git tag ios-release-<n> && git push origin ios-release-<n>`.
