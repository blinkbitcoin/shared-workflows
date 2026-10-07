#!/usr/bin/env bash
# The Expo stack's Metro, `expo start` in the background; scripts/e2e/metro-start.sh
# dispatches here through scripts/lib/native-stack.sh. The log, pid and process
# group contract is workflows_metro_background's, in scripts/lib/e2e-metro.sh.
# Log: $WORKFLOWS_OUT/metro.log  Pid: $WORKFLOWS_OUT/metro.pid
# Usage: metro-start.sh
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
source "$(dirname "$0")/../../lib/e2e-env.sh"

require_cmd pnpm
root="$(consumer_root)"
cd "$root"

args=(expo start --port "$WORKFLOWS_METRO_PORT")
# A dev-client build is not an Expo Go client: without the flag `expo start`
# advertises an exp:// URL the installed app cannot open.
[ "$WORKFLOWS_DEV_CLIENT" = "true" ] && args+=(--dev-client)

workflows_metro_background pnpm exec "${args[@]}"
