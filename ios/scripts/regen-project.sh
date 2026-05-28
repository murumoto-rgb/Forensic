#!/usr/bin/env bash
# Regenerates the iOS Xcode project.
#
# Two steps:
#   1. Generate `ios/SitePhoto/Generated/BuildInfo.swift` with the
#      current git SHA + timestamp.
#   2. Run `xcodegen generate` to rebuild `ios/SitePhoto.xcodeproj`.
#
# Use this every time you'd previously have run `xcodegen generate`
# on its own — pulling a new branch, switching branches, etc. The
# step #1 keeps `BuildInfo.display` in sync with the current commit
# so the in-app "About" row matches what's actually deployed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

"${SCRIPT_DIR}/gen-build-info.sh"
cd "${IOS_DIR}"
xcodegen generate
