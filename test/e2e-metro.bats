#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/e2e-metro.sh: the host-side services of the E2E env contract.
# Covered here: the Metro and mock API port defaults, an override of each and
# an empty mock API port kept empty (it disables the reverse), that sourcing it
# creates nothing, and workflows_metro_background starting its command in its
# own process group with CI=1, the log and the pid file.
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/ghenv"
  : > "$GITHUB_ENV"
  unset WORKFLOWS_METRO_PORT WORKFLOWS_MOCK_API_PORT
}

# The background command has written its whole line into metro.log.
metro_logged() {
  [ -s "$WORKFLOWS_OUT/metro.log" ] && [ -z "$(tail -c 1 "$WORKFLOWS_OUT/metro.log")" ]
}

# metro_env COMMANDS - runs COMMANDS in a fresh bash that has sourced common.sh
# and this library, under the options every caller sets.
metro_env() {
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/e2e-metro.sh"; eval "$2"' _ "$REPO_ROOT" "$1"
}

@test "Metro defaults to 8081 and the mock API to 8082, and both reach child processes" {
  metro_env 'bash -c "printf \"%s|%s\\n\" \"\$WORKFLOWS_METRO_PORT\" \"\$WORKFLOWS_MOCK_API_PORT\""'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "8081|8082" ] || fail "got '$output'"
}

@test "a set port keeps its value, and an empty mock API port stays empty" {
  WORKFLOWS_METRO_PORT=9091 WORKFLOWS_MOCK_API_PORT=9092 metro_env 'printf "%s|%s\n" "$WORKFLOWS_METRO_PORT" "$WORKFLOWS_MOCK_API_PORT"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "9091|9092" ] || fail "got '$output'"
  WORKFLOWS_MOCK_API_PORT="" metro_env 'printf "[%s]\n" "$WORKFLOWS_MOCK_API_PORT"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "[]" ] || fail "an empty mock API port was defaulted: $output"
}

@test "sourcing it creates nothing and publishes nothing" {
  metro_env 'true'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -e "$WORKFLOWS_OUT" ] || fail "sourcing the library created $WORKFLOWS_OUT"
  [ ! -s "$GITHUB_ENV" ] || fail "sourcing the library published: $(cat "$GITHUB_ENV")"
}

@test "workflows_metro_background starts the command in its own process group, with the log and PID" {
  mkdir -p "$WORKFLOWS_OUT"
  run bash -c "set -euo pipefail
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-metro.sh'
    WORKFLOWS_METRO_PORT=9999 workflows_metro_background bash -c 'printf \"CI=%s pgid=%s\\n\" \"\$CI\" \"\$(ps -o pgid= -p \$\$ | tr -d \" \")\"'"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  pid="$(cat "$WORKFLOWS_OUT/metro.pid")"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "not a PID: $pid"
  contains "$output" "Metro starting (pid $pid, port 9999, log $WORKFLOWS_OUT/metro.log)" || fail "output: $output"
  contains "$output" "stop it with: kill -TERM -$pid" || fail "output: $output"
  wait_for 60 "the command's line in metro.log" metro_logged
  [ "$(cat "$WORKFLOWS_OUT/metro.log")" = "CI=1 pgid=$pid" ] \
    || fail "the command did not run with CI=1 as its own process group's leader: $(cat "$WORKFLOWS_OUT/metro.log")"
}
