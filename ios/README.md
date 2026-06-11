# SitePhoto — Native iOS

Native iOS port of the SitePhoto web app.

## First-time setup on the Mac

```bash
brew install xcodegen
./ios/scripts/regen-project.sh
open ios/SitePhoto.xcodeproj
```

In Xcode: select the SitePhoto target → **Signing & Capabilities** → set your team to your Apple ID. Plug in your iPhone, choose it as the build target, hit ⌘R.

> **Don't run `xcodegen` directly.** The wrapper script `ios/scripts/regen-project.sh` is the canonical entry point — it runs `gen-build-info.sh` first (which writes the gitignored `ios/SitePhoto/Generated/BuildInfo.swift` that the in-app **About** section reads for the git SHA / branch / timestamp), then `xcodegen generate`. Skipping the wrapper builds with stale or missing build info. See `CLAUDE.md` for the full breakdown.

## Day-to-day workflow

The one-liner — pull, regen, build, install, launch — is `scripts/sync-ios.sh`:

```bash
cd ~/Developer/Forensic
scripts/sync-ios.sh main           # or scripts/sync-ios.sh <branch>
```

That replaces the older manual sequence (`git pull && ./ios/scripts/regen-project.sh && open ios/SitePhoto.xcodeproj` then ⌘R). Either path works; the sync script is preferred because it handles device detection + provisioning + launch in one shot.

If you just want to regenerate the project after a `project.yml` change without building:

```bash
./ios/scripts/regen-project.sh
```

Then ⌘R in Xcode (cable workflow) or wait for TestFlight (CI workflow).

## Why XcodeGen?

The `.xcodeproj` is generated from `project.yml` rather than committed. Adding files, changing settings, or bumping the deployment target is a YAML edit Claude can make — no Xcode UI clicks required.
