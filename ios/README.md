# SitePhoto — Native iOS

Native iOS port of the SitePhoto web app.

## First-time setup on the Mac

```bash
brew install xcodegen
cd ios
xcodegen
open SitePhoto.xcodeproj
```

In Xcode: select the SitePhoto target → **Signing & Capabilities** → set your team to your Apple ID. Plug in your iPhone, choose it as the build target, hit ⌘R.

## Day-to-day workflow

After Claude pushes Swift edits:

```bash
git pull
cd ios
xcodegen   # only if project.yml changed
```

Then ⌘R in Xcode (cable workflow) or wait for TestFlight (CI workflow).

## Why XcodeGen?

The `.xcodeproj` is generated from `project.yml` rather than committed. Adding files, changing settings, or bumping the deployment target is a YAML edit Claude can make — no Xcode UI clicks required.
