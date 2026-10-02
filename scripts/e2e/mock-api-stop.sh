#!/usr/bin/env bash
# Stop the mock API mock-api-start.sh started. Always exits 0: it runs after a
# suite that may have failed, and a teardown that fails would hide that failure.
#
# Usage: mock-api-stop.sh   Env: WORKFLOWS_OUT
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

pid_file="$WORKFLOWS_OUT/mock-api.pid"
if [ ! -f "$pid_file" ]; then
  log "no $pid_file - no mock API to stop"
  exit 0
fi
pid="$(cat "$pid_file")"
rm -f "$pid_file"
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  # The whole group, so the package manager's child is not left holding the port.
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  log "mock API (pid $pid) stopped"
else
  log "mock API (pid ${pid:-?}) was no longer running"
fi
exit 0
