#!/usr/bin/env bash
# Xcode Cloud post-clone hook. Runs in Xcode Cloud's macOS sandbox
# AFTER the repo is cloned and BEFORE xcodebuild starts.
#
# This script must live at `ios/ci_scripts/ci_post_clone.sh`
# because Xcode Cloud looks for ci_scripts as a sibling of the
# .xcodeproj. The cwd when the script runs is `ios/ci_scripts/`.
#
# Responsibilities:
#   1. Install `xcodegen` via Homebrew (Xcode Cloud's image ships
#      with Homebrew preinstalled but no xcodegen).
#   2. Regenerate `ios/SitePhoto.xcodeproj` so Xcode Cloud builds
#      from the same project graph local builds use.
#   3. Stamp `CFBundleVersion` with Xcode Cloud's auto-incrementing
#      `CI_BUILD_NUMBER` — TestFlight requires each upload's
#      CFBundleVersion to be unique within a CFBundleShortVersionString.
#
# This script does NOT run for local builds (Xcode Cloud is the
# only caller). Local builds get whatever CFBundleVersion is set in
# `ios/project.yml` (currently "1"), which is fine because local
# builds never upload to TestFlight.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${IOS_DIR}/.." && pwd)"

echo "==> ci_post_clone: starting in $(pwd)"
echo "    repo root: ${REPO_ROOT}"

# 1. xcodegen (Xcode Cloud image has Homebrew; xcodegen is not preinstalled)
if ! command -v xcodegen >/dev/null; then
  echo "==> Installing xcodegen via Homebrew"
  brew install xcodegen
else
  echo "==> xcodegen already on PATH ($(xcodegen --version))"
fi

# 2. Regenerate the Xcode project (gen-build-info.sh + xcodegen generate)
echo "==> Regenerating Xcode project"
"${IOS_DIR}/scripts/regen-project.sh"

# 3. Stamp CFBundleVersion with Xcode Cloud's per-run integer.
#    `CI_BUILD_NUMBER` is set by Xcode Cloud and increments on every
#    workflow run — exactly what TestFlight wants. The generated
#    Info.plist sits at ios/SitePhoto/Info.plist (xcodegen wrote it
#    a moment ago).
INFO_PLIST="${IOS_DIR}/SitePhoto/Info.plist"
if [ ! -f "${INFO_PLIST}" ]; then
  echo "error: Info.plist not found at ${INFO_PLIST} after xcodegen" >&2
  exit 1
fi

if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  echo "==> Setting CFBundleVersion = ${CI_BUILD_NUMBER}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CI_BUILD_NUMBER}" "${INFO_PLIST}"
else
  echo "    CI_BUILD_NUMBER not set — leaving CFBundleVersion as-is."
  echo "    (This is expected outside of Xcode Cloud; if you're seeing"
  echo "     it inside Xcode Cloud, Apple changed the env-var name.)"
fi

# 4. (Optional) align CFBundleShortVersionString with the registry
#    build #. Comment-toggleable so the App Store Connect "Version"
#    column doesn't proliferate on every merge to main. Off by
#    default — toggle SITEPHOTO_SYNC_SHORT_VERSION=1 in the Xcode
#    Cloud workflow env to enable.
if [ "${SITEPHOTO_SYNC_SHORT_VERSION:-0}" = "1" ]; then
  BUILDS_FILE="${REPO_ROOT}/docs/builds.md"
  if [ -f "${BUILDS_FILE}" ]; then
    SHORT_VERSION=$(grep -oE '^## Build [0-9]+(\.[0-9]+)*' "${BUILDS_FILE}" \
                    | head -1 \
                    | sed -E 's/^## Build //')
    if [ -n "${SHORT_VERSION}" ]; then
      echo "==> Setting CFBundleShortVersionString = ${SHORT_VERSION}"
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${SHORT_VERSION}" "${INFO_PLIST}"
    fi
  fi
fi

echo "==> ci_post_clone: done"
