#!/usr/bin/env bash
# The Expo stack's prebuild; scripts/native/prebuild.sh dispatches here through
# scripts/lib/native-stack.sh. Regenerates the native project for one platform
# from app.config.* + config plugins. `--clean` on purpose: CI must never build on top of a stale ios/ or
# android/ tree restored from a cache. `--no-install` because dependencies are
# already installed by the workflow (and pods are pods.sh's job).
# Usage: prebuild.sh <ios|android>
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
source "$(dirname "$0")/../../lib/e2e-env.sh"

platform="$(workflows_platform "${1:-}")"
require_cmd pnpm
root="$(consumer_root)"
cd "$root"

group "expo prebuild ($platform)"
CI=1 EXPO_NO_GIT_STATUS=1 pnpm exec expo prebuild --platform "$platform" --clean --no-install
endgroup
