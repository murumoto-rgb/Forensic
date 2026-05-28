#!/usr/bin/env bash
# Thin wrapper that runs the TS regen script via pnpm-managed tsx.
# Usage:  pnpm parity:regen-fixtures   (preferred)
#         scripts/regen-ios-fixtures.sh
set -euo pipefail
cd "$(dirname "$0")/.."
pnpm --filter @forensic/shared exec tsx "$(pwd)/scripts/regen-ios-fixtures.ts"
