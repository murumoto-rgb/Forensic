#!/usr/bin/env bash
# scripts/sync-ios.sh
#
# One-command pull + regen + build + install for the iOS app on a
# tethered iPhone. Replaces the manual loop of
#
#   git fetch && git checkout && git pull && \
#     ./ios/scripts/regen-project.sh && open ios/SitePhoto.xcodeproj
#   ... then ⌘R in Xcode
#
# Usage:
#   scripts/sync-ios.sh                # build whatever branch is checked out
#   scripts/sync-ios.sh main           # switch to main, pull, build
#   scripts/sync-ios.sh <branch>       # switch to <branch>, pull, build
#   scripts/sync-ios.sh --pr <N>       # `gh pr checkout <N>`, build
#   scripts/sync-ios.sh --help
#
# Env-var overrides:
#   SITEPHOTO_DEVICE_UDID   skip auto-detect; build to this UDID
#   SITEPHOTO_SKIP_GIT=1    skip git fetch/pull (offline rebuilds)
#   SITEPHOTO_NO_LAUNCH=1   install but don't launch (handy when
#                           the screen is already on SitePhoto)
#
# Requires:
#   - Xcode 15+ (for `xcrun devicectl`)
#   - xcodegen on PATH
#   - One iPhone or iPad tethered, unlocked, "Trust This Computer"
#     granted
#   - For --pr mode: `gh` CLI authenticated to GitHub

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# ---------- 1. parse args ----------

MODE="current"
TARGET=""

if [[ $# -gt 0 ]]; then
  case "$1" in
    --pr)
      shift
      [[ $# -gt 0 ]] || { echo "error: --pr needs a PR number" >&2; exit 2; }
      MODE="pr"
      TARGET="$1"
      ;;
    --help|-h)
      # Print the header block above (lines up to the first blank
      # line after the shebang).
      awk 'NR>1 && /^[^#]/{exit} NR>1{sub(/^# ?/,""); print}' "$0"
      exit 0
      ;;
    -*)
      echo "error: unknown flag $1 (try --help)" >&2; exit 2
      ;;
    *)
      MODE="branch"
      TARGET="$1"
      ;;
  esac
fi

# ---------- 2. git sync ----------

if [[ "${SITEPHOTO_SKIP_GIT:-0}" == "1" ]]; then
  echo "==> Skipping git sync (SITEPHOTO_SKIP_GIT=1)"
else
  case "$MODE" in
    current)
      BRANCH=$(git rev-parse --abbrev-ref HEAD)
      if [[ "$BRANCH" == "HEAD" ]]; then
        echo "error: detached HEAD. Pass a branch name or --pr <N>." >&2
        exit 2
      fi
      echo "==> Fetching origin"
      git fetch origin
      echo "==> Pulling $BRANCH (fast-forward only)"
      git pull --ff-only origin "$BRANCH"
      ;;
    branch)
      echo "==> Fetching origin"
      git fetch origin
      echo "==> Switching to $TARGET"
      git checkout "$TARGET"
      git pull --ff-only origin "$TARGET"
      ;;
    pr)
      command -v gh >/dev/null || {
        echo "error: gh CLI not installed." >&2
        echo "       brew install gh && gh auth login" >&2
        exit 3
      }
      echo "==> Checking out PR #$TARGET"
      gh pr checkout "$TARGET"
      ;;
  esac
fi

# ---------- 3. regen Xcode project ----------

echo "==> Regenerating iOS Xcode project"
"$REPO_ROOT/ios/scripts/regen-project.sh"

# ---------- 4. find the device ----------

if [[ -n "${SITEPHOTO_DEVICE_UDID:-}" ]]; then
  UDID="$SITEPHOTO_DEVICE_UDID"
  DEVICE_NAME="(from SITEPHOTO_DEVICE_UDID)"
else
  echo "==> Detecting tethered iPhone via xctrace"
  # `xctrace list devices` prints physical devices under a
  # "== Devices ==" header, then simulators under
  # "== Devices Offline ==" / "== Simulators ==". We take the first
  # physical iPhone/iPad line.
  DEVICE_LINE=$(xcrun xctrace list devices 2>&1 \
    | awk '/^== Devices ==/{flag=1; next} /^==/{flag=0} flag' \
    | grep -E "iPhone|iPad" \
    | head -1 || true)
  if [[ -z "$DEVICE_LINE" ]]; then
    echo "error: no tethered iPhone/iPad detected." >&2
    echo "       Plug in your device, unlock it, tap 'Trust This Computer'." >&2
    echo "       Or set SITEPHOTO_DEVICE_UDID explicitly." >&2
    exit 4
  fi
  # Trailing parenthesised UDID, e.g. "Mehmet's iPhone (17.4) (00008110-...)"
  UDID=$(echo "$DEVICE_LINE" | grep -oE "\([0-9A-Za-z-]+\)" | tail -1 | tr -d "()")
  DEVICE_NAME=$(echo "$DEVICE_LINE" | sed 's/ *([^()]*) *([^()]*)$//')
  if [[ -z "$UDID" ]]; then
    echo "error: could not parse UDID from line: $DEVICE_LINE" >&2
    exit 5
  fi
fi
echo "    device: $DEVICE_NAME"
echo "    udid:   $UDID"

# ---------- 5. build ----------

if ! command -v xcodebuild >/dev/null; then
  echo "error: xcodebuild not found. Install Xcode from the App Store." >&2
  exit 6
fi

DERIVED="$REPO_ROOT/ios/build"
echo "==> Building SitePhoto (Debug)"
xcodebuild \
  -project "$REPO_ROOT/ios/SitePhoto.xcodeproj" \
  -scheme SitePhoto \
  -destination "platform=iOS,id=$UDID" \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -quiet \
  build

APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/SitePhoto.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built .app not found at $APP_PATH" >&2
  exit 7
fi

# ---------- 6. install + launch ----------

if ! xcrun devicectl --version >/dev/null 2>&1; then
  echo "error: xcrun devicectl unavailable (Xcode 15+ required)." >&2
  echo "       For older Xcode: brew install ios-deploy, then" >&2
  echo "       ios-deploy --bundle '$APP_PATH' --justlaunch" >&2
  exit 8
fi

echo "==> Installing on device"
xcrun devicectl device install app --device "$UDID" "$APP_PATH" >/dev/null

if [[ "${SITEPHOTO_NO_LAUNCH:-0}" != "1" ]]; then
  echo "==> Launching SitePhoto"
  xcrun devicectl device process launch \
    --device "$UDID" \
    com.murumoto.sitephoto >/dev/null
fi

SHA=$(git rev-parse --short HEAD)
echo
echo "Done. Commit $SHA installed on $DEVICE_NAME."
