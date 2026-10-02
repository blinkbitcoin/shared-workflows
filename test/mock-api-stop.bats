#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/mock-api-stop.sh: stops the mock API mock-api-start.sh started, whole process group, and never fails.
# These run a real process (python's http.server stands in for a mock API),
# because what matters is the process lifecycle.

load test_helper

setup() {
  command -v python3 >/dev/null || skip "python3 is not installed"
  command -v curl >/dev/null || skip "curl is not installed"
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY="consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out-dir"
  mkdir -p "$RUNNER_TEMP"
  PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  export WORKFLOWS_MOCK_API_PORT="$PORT"
  START="$REPO_ROOT/scripts/e2e/mock-api-start.sh"
  STOP="$REPO_ROOT/scripts/e2e/mock-api-stop.sh"
  WAIT="$REPO_ROOT/scripts/e2e/wait-for-http.sh"
  # A server that listens on MOCK_API_PORT, as a consumer's mock API does.
  SERVER='python3 -m http.server "$MOCK_API_PORT" --bind 127.0.0.1'
}

teardown() {
  bash "$STOP" >/dev/null 2>&1 || true
}

@test "stop takes down the whole process group, not only the shell that started it" {
  WORKFLOWS_MOCK_API_PORT="" MOCK_API_COMMAND="sh -c 'echo \$\$ > child.pid; exec sleep 300' & wait" bash "$START" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CONSUMER/child.pid" ] && break; sleep 0.2; done
  child="$(cat "$CONSUMER/child.pid")"
  kill -0 "$child" || fail "the child never started"
  run bash "$STOP"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "stopped" || fail "output: $output"
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$child" 2>/dev/null || break; sleep 0.2; done
  ! kill -0 "$child" 2>/dev/null || fail "the child $child is still running"
  [ ! -f "$WORKFLOWS_OUT/mock-api.pid" ] || fail "the pid file is still there"
}

@test "stop with nothing started, or after the server already exited, is not an error" {
  run bash "$STOP"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "no mock API to stop" || fail "output: $output"
  WORKFLOWS_MOCK_API_PORT="" MOCK_API_COMMAND="true" bash "$START" >/dev/null 2>&1
  sleep 0.5
  run bash "$STOP"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "was no longer running" || fail "output: $output"
}
