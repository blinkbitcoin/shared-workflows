#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/wait-for-http.sh: waits until an HTTP server answers, whatever the status.
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

@test "wait-for-http returns once a server answers, whatever the status" {
  (cd "$BATS_TEST_TMPDIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 3>&-) &
  pid=$!
  run bash "$WAIT" "http://127.0.0.1:$PORT/no-such-route" 10
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "a 404 is still an answer: $output"
}

@test "wait-for-http fails naming the URL and the wait when nothing answers" {
  run bash "$WAIT" "http://127.0.0.1:$PORT/" 1
  [ "$status" -ne 0 ] || fail "nothing was listening: $output"
  contains "$output" "nothing answered at http://127.0.0.1:$PORT/ within 1s" || fail "output: $output"
}

@test "wait-for-http rejects a wait that is not a whole number, and a missing URL" {
  run bash "$WAIT" "http://127.0.0.1:$PORT/" soon
  [ "$status" -ne 0 ] || fail "accepted a non-number: $output"
  contains "$output" "SECONDS must be a whole number, got 'soon'" || fail "output: $output"
  run bash "$WAIT"
  [ "$status" -ne 0 ] || fail "accepted no URL: $output"
}
