#!/usr/bin/env bash
# Start the consumer's mock API for an E2E suite, in the background, and wait
# until it answers.
#
# The suite's app talks to a server on this machine (the iOS simulator shares its
# host's network; the Android emulator reaches it through `adb reverse`, which
# android-emulator.sh sets up from the same WORKFLOWS_MOCK_API_PORT). Starting it
# was a script every consumer wrote for itself - nohup, a pid file, a wait loop, a
# log to print when it never came up - so the command is all a consumer names now.
#
# The command runs in the consumer's working directory with MOCK_API_PORT set to
# WORKFLOWS_MOCK_API_PORT (8082 unless the consumer moved it), so a server that
# reads MOCK_API_PORT follows the port the emulator reverses. It runs in its own
# process group, so mock-api-stop.sh takes down the package manager's child
# processes with it rather than leaving a node server holding the port.
#
# Usage: mock-api-start.sh   Env: MOCK_API_COMMAND (required), WORKFLOWS_MOCK_API_PORT
# (empty skips the wait), WORKFLOWS_OUT (the pid file and the log live there).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

command_line="${MOCK_API_COMMAND:-}"
[ -n "$command_line" ] || die "mock-api-start: MOCK_API_COMMAND is empty - pass mock-api-command to test-e2e.yml"

root="$(consumer_root)"
log_file="$WORKFLOWS_OUT/mock-api.log"
pid_file="$WORKFLOWS_OUT/mock-api.pid"
[ ! -f "$pid_file" ] || die "mock-api-start: $pid_file exists, so a mock API is already started in this job"

# `set -m` puts the background job in its own process group; its pid is then the
# group id mock-api-stop.sh signals.
set -m
# fd 3 is closed in the child: a test runner (bats) keeps its report open on it, and a
# server that inherits it holds the runner waiting until the server exits.
(cd "$root" && exec env MOCK_API_PORT="$WORKFLOWS_MOCK_API_PORT" bash -c "$command_line") >"$log_file" 2>&1 3>&- </dev/null &
pid=$!
set +m
printf '%s\n' "$pid" >"$pid_file"
log "mock API started (pid $pid, port ${WORKFLOWS_MOCK_API_PORT:-none}, log $log_file): $command_line"

[ -n "$WORKFLOWS_MOCK_API_PORT" ] || {
  log "WORKFLOWS_MOCK_API_PORT is empty: not waiting for the mock API"
  exit 0
}
if ! bash "$(dirname "$0")/wait-for-http.sh" "http://localhost:$WORKFLOWS_MOCK_API_PORT/" "${WORKFLOWS_MOCK_API_WAIT_SECONDS:-60}"; then
  log "--- tail of $log_file ---"
  tail -50 "$log_file" >&2 || true
  die "the mock API did not come up on port $WORKFLOWS_MOCK_API_PORT: $command_line"
fi
log "mock API is up on port $WORKFLOWS_MOCK_API_PORT"
