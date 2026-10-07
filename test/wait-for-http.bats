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

# Something accepts a connection on 127.0.0.1:PORT.
listening() { python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2).close()' "$1" 2>/dev/null; }

# A server that takes the connection and never answers costs each try its whole
# 2s curl timeout. Bounded by a count of tries, 3 seconds meant 3 tries of 2s
# each plus 1s between them, 9s; bounded by the clock it is one try past 3s.
@test "wait-for-http gives up at the stated wait in real time, even when each try is slow" {
  python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
time.sleep(60)
' "$PORT" >/dev/null 2>&1 3>&- &
  pid=$!
  # Poll for the listener rather than sleeping a fixed time.
  wait_for 60 "the silent server to listen on port $PORT" listening "$PORT"
  run bash "$WAIT" "http://127.0.0.1:$PORT/" 3
  kill "$pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "a server that never answered passed: $output"
  contains "$output" "nothing answered at http://127.0.0.1:$PORT/ within 3s (gave up after " || fail "output: $output"
  gave_up="$(sed -n 's/.*(gave up after \([0-9][0-9]*\)s).*/\1/p' <<<"$output")"
  [ -n "$gave_up" ] && [ "$gave_up" -ge 3 ] || fail "gave up before the stated wait: $output"
  [ "$gave_up" -lt 9 ] || fail "waited a count of tries, not the clock: $output"
}

@test "wait-for-http rejects a wait that is not a whole number, and a missing URL" {
  run bash "$WAIT" "http://127.0.0.1:$PORT/" soon
  [ "$status" -ne 0 ] || fail "accepted a non-number: $output"
  contains "$output" "SECONDS must be a whole number, got 'soon'" || fail "output: $output"
  run bash "$WAIT"
  [ "$status" -ne 0 ] || fail "accepted no URL: $output"
}
