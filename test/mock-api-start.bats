#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/mock-api-start.sh: starts the consumer's mock API in the background and waits for it to answer.
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

@test "start refuses an empty command, naming the workflow input" {
  MOCK_API_COMMAND="" run bash "$START"
  [ "$status" -ne 0 ] || fail "started nothing and said ok: $output"
  contains "$output" "MOCK_API_COMMAND is empty - pass mock-api-command to test-e2e.yml" || fail "output: $output"
}

@test "start runs the command in the consumer's directory with the port in its environment, and waits for an answer" {
  MOCK_API_COMMAND="pwd > where.txt; echo \"\$MOCK_API_PORT\" > port.txt; $SERVER" run bash "$START"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "mock API is up on port $PORT" || fail "output: $output"
  [ "$(cat "$CONSUMER/where.txt")" = "$(cd "$CONSUMER" && pwd -P)" ] || fail "ran in $(cat "$CONSUMER/where.txt")"
  [ "$(cat "$CONSUMER/port.txt")" = "$PORT" ] || fail "MOCK_API_PORT was $(cat "$CONSUMER/port.txt")"
  [ -s "$WORKFLOWS_OUT/mock-api.pid" ] || fail "no pid file"
  curl -sS -o /dev/null "http://127.0.0.1:$PORT/" || fail "the server is not answering"
}

@test "a server that never comes up fails with the tail of its own log" {
  WORKFLOWS_MOCK_API_WAIT_SECONDS=1 MOCK_API_COMMAND="echo 'cannot bind: boom' >&2; sleep 30" run bash "$START"
  [ "$status" -ne 0 ] || fail "a dead server passed: $output"
  contains "$output" "tail of $WORKFLOWS_OUT/mock-api.log" || fail "no log tail: $output"
  contains "$output" "cannot bind: boom" || fail "the server's own error was dropped: $output"
  contains "$output" "the mock API did not come up on port $PORT" || fail "output: $output"
}

@test "an empty port starts the command and does not wait" {
  WORKFLOWS_MOCK_API_PORT="" MOCK_API_COMMAND="sleep 30" run bash "$START"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "WORKFLOWS_MOCK_API_PORT is empty: not waiting for the mock API" || fail "output: $output"
}

@test "a second start in the same job is refused" {
  WORKFLOWS_MOCK_API_PORT="" MOCK_API_COMMAND="sleep 30" bash "$START" >/dev/null 2>&1
  WORKFLOWS_MOCK_API_PORT="" MOCK_API_COMMAND="sleep 30" run bash "$START"
  [ "$status" -ne 0 ] || fail "started twice: $output"
  contains "$output" "a mock API is already started in this job" || fail "output: $output"
}
