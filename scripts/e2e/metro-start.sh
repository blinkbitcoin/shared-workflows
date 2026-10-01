#!/usr/bin/env bash
# Start Metro in the background so its boot overlaps the rest of the setup;
# metro-wait.sh awaits it. The consumer's native stack decides the command -
# `expo start` for Expo, `react-native start` for a bare app - and
# scripts/lib/native-stack.sh runs scripts/native/<stack>/metro-start.sh. Both
# share one contract (workflows_metro_background in scripts/lib/e2e-env.sh).
#
# Kept at this path, a thin dispatcher, rather than removed: test-e2e.yml, the
# E2E README and a laptop run of the suite all call `scripts/e2e/metro-start.sh`.
# Log: $WORKFLOWS_OUT/metro.log  Pid: $WORKFLOWS_OUT/metro.pid
# Usage: metro-start.sh
set -euo pipefail
exec bash "$(dirname "$0")/../lib/native-stack.sh" metro-start "$@"
