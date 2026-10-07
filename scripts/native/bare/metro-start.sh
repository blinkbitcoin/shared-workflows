#!/usr/bin/env bash
# The bare stack's Metro, `react-native start` in the background, through the
# consumer's own @react-native-community/cli (`pnpm exec`); scripts/e2e/metro-start.sh
# dispatches here through scripts/lib/native-stack.sh. The log, pid and process
# group contract is workflows_metro_background's, in scripts/lib/e2e-metro.sh,
# the same one the Expo stack uses, so metro-wait.sh, app-launch.sh and the
# forensics read both alike.
#
# No --dev-client: that is an `expo start` flag. A bare app has no dev-client
# launcher; it loads the bundle from the port it was built against.
# Log: $WORKFLOWS_OUT/metro.log  Pid: $WORKFLOWS_OUT/metro.pid
# Usage: metro-start.sh
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
source "$(dirname "$0")/../../lib/e2e-env.sh"

require_cmd pnpm
root="$(consumer_root)"
cd "$root"

workflows_metro_background pnpm exec react-native start --port "$WORKFLOWS_METRO_PORT"
