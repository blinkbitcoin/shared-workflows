#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/ios-maestro.sh: the Maestro suite on the picked simulator, retried
# once unless it hung, and green only when the junit report shows flows ran.
# maestro is a fake: it records each call, writes a junit report with
# MAESTRO_TESTS flows, and exits with the next status in MAESTRO_STATUSES.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export HOME="$BATS_TEST_TMPDIR/home"
  export WORKFLOWS_SIM_UDID=SIM-1 WORKFLOWS_APP_ID=com.example.app
  mkdir -p "$GITHUB_WORKSPACE/.maestro" "$HOME"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  cat > "$bin/maestro" <<'STUB'
#!/usr/bin/env bash
printf 'maestro %s\n' "$*" >> "$CALLS"
n=$(grep -c '^maestro ' "$CALLS")
set -- "$@" ""
out=""
while [ "$#" -gt 1 ]; do [ "$1" = --output ] && out="$2"; shift; done
[ -n "$out" ] && printf '<testsuites tests="%s"/>\n' "${MAESTRO_TESTS:-3}" > "$out"
read -r -a statuses <<< "${MAESTRO_STATUSES:-0}"
exit "${statuses[$((n - 1))]:-0}"
STUB
  chmod +x "$bin/maestro"
  export PATH="$bin:/usr/bin:/bin"
}

suite() { run bash "$REPO_ROOT/scripts/e2e/ios-maestro.sh"; }

@test "runs the flows on the picked simulator with the app id, debug output and a junit report" {
  suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$CALLS")" = "maestro test .maestro --platform ios --udid SIM-1 -e APP_ID=com.example.app --debug-output $WORKFLOWS_OUT/maestro --flatten-debug-output --format junit --output $WORKFLOWS_OUT/maestro/junit.xml" ] \
    || fail "calls: $(cat "$CALLS")"
  contains "$output" "iOS: Maestro ran 3 flow(s)" || fail "output: $output"
}

@test "passes the flows' config.yaml and the tag filters when there are any" {
  touch "$GITHUB_WORKSPACE/.maestro/config.yaml"
  WORKFLOWS_MAESTRO_INCLUDE_TAGS=smoke WORKFLOWS_MAESTRO_EXCLUDE_TAGS=slow suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  calls="$(cat "$CALLS")"
  contains "$calls" "--config .maestro/config.yaml" || fail "calls: $calls"
  contains "$calls" "--include-tags smoke --exclude-tags slow" || fail "calls: $calls"
}

@test "a failed suite is rerun once, and the rerun's green counts" {
  MAESTRO_STATUSES="1 0" suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(grep -c '^maestro ' "$CALLS")" -eq 2 ] || fail "calls: $(cat "$CALLS")"
  contains "$output" "Maestro suite failed (status 1) - rerunning the suite once" || fail "output: $output"
}

@test "a suite that fails twice fails with the rerun's status" {
  MAESTRO_STATUSES="1 2" suite
  [ "$status" -eq 2 ] || fail "expected 2, got $status: $output"
}

@test "a hung suite (124) is not rerun" {
  MAESTRO_STATUSES=124 suite
  [ "$status" -eq 124 ] || fail "expected 124, got $status: $output"
  [ "$(grep -c '^maestro ' "$CALLS")" -eq 1 ] || fail "reran a hung suite: $(cat "$CALLS")"
}

@test "a green suite that ran no flows fails" {
  MAESTRO_TESTS=0 suite
  [ "$status" -ne 0 ] || fail "passed with no flows: $output"
  contains "$output" "Maestro exited 0 but ran 0 flows" || fail "output: $output"
}

@test "the setup hook runs before the suite and the teardown hook after it" {
  printf 'echo setup >> "$CALLS"\n' > "$GITHUB_WORKSPACE/up.sh"
  printf 'echo teardown >> "$CALLS"\n' > "$GITHUB_WORKSPACE/down.sh"
  WORKFLOWS_E2E_SETUP_SCRIPT=up.sh WORKFLOWS_E2E_TEARDOWN_SCRIPT=down.sh suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(sed 's/ .*//' "$CALLS" | tr '\n' ' ')" = "setup maestro teardown " ] || fail "order: $(cat "$CALLS")"
}

@test "a failing setup hook stops before the suite, and teardown still runs" {
  printf 'exit 1\n' > "$GITHUB_WORKSPACE/up.sh"
  printf 'echo teardown >> "$CALLS"\n' > "$GITHUB_WORKSPACE/down.sh"
  WORKFLOWS_E2E_SETUP_SCRIPT=up.sh WORKFLOWS_E2E_TEARDOWN_SCRIPT=down.sh suite
  [ "$status" -ne 0 ] || fail "ran after a failed setup: $output"
  contains "$output" "WORKFLOWS_E2E_SETUP_SCRIPT failed" || fail "output: $output"
  [ "$(cat "$CALLS")" = "teardown" ] || fail "calls: $(cat "$CALLS")"
}

@test "no flows directory fails, naming it" {
  rmdir "$GITHUB_WORKSPACE/.maestro"
  suite
  [ "$status" -ne 0 ] || fail "ran without flows: $output"
  contains "$output" "no flows directory at" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "ran anyway: $(cat "$CALLS")"
}

@test "a driver startup timeout at or over the suite bound fails before the suite" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=600000 suite
  [ "$status" -ne 0 ] || fail "accepted a timeout over the bound: $output"
  contains "$output" "is not below the suite bound" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "ran anyway: $(cat "$CALLS")"
}

@test "no maestro anywhere is named" {
  rm "$bin/maestro"
  suite
  [ "$status" -ne 0 ] || fail "ran without maestro: $output"
  contains "$output" "missing command: maestro" || fail "output: $output"
}

@test "finds maestro in ~/.maestro/bin, where its installer puts it" {
  mkdir -p "$HOME/.maestro/bin"
  mv "$bin/maestro" "$HOME/.maestro/bin/maestro"
  suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
}
