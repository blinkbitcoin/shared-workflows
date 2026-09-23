#!/usr/bin/env bats
# MAESTRO_DRIVER_STARTUP_TIMEOUT must be strictly below the suite bound. Maestro
# throws a real exception when it expires, which the maestro scripts rerun once;
# a value at or above the bound means the bound's exit 124 - never retried -
# fires first, and a driver that failed to launch costs the whole bound with
# zero flows run (run 35259139324: ten minutes, TEST EXECUTE FAILED at 77s).
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/ghenv"
  : > "$GITHUB_ENV"
  mkdir -p "$WORKFLOWS_OUT"
  unset MAESTRO_DRIVER_STARTUP_TIMEOUT WORKFLOWS_SUITE_TIMEOUT_MINUTES
}

timeout_for() { # DEFAULT_MS, with the caller's environment
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'; workflows_driver_startup_timeout $1"
}

@test "the default is used when nothing is set, and it is below the default bound" {
  timeout_for 300000
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ "$output" = "300000" ] || fail "got '$output'"
  [ "$output" -lt $((10 * 60 * 1000)) ] || fail "300000 is not below the 10-minute bound"
}

@test "an explicit environment value wins" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=120000 timeout_for 300000
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ "$output" = "120000" ] || fail "got '$output'"
}

@test "a value equal to the bound is refused - that was the shipped configuration" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=600000 timeout_for 300000
  [ "$status" -ne 0 ] || fail "600000 against a 10-minute bound was accepted"
  contains "$output" "not below the suite bound" || fail "output: $output"
}

@test "the bound follows WORKFLOWS_SUITE_TIMEOUT_MINUTES" {
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=4 MAESTRO_DRIVER_STARTUP_TIMEOUT=300000 timeout_for 300000
  [ "$status" -ne 0 ] || fail "300000 against a 4-minute bound was accepted"
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=6 MAESTRO_DRIVER_STARTUP_TIMEOUT=300000 timeout_for 300000
  [ "$status" -eq 0 ] || fail "300000 against a 6-minute bound was refused: $output"
}

@test "a non-numeric value is refused rather than exported" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=5m timeout_for 300000
  [ "$status" -ne 0 ] || fail "'5m' was accepted"
  contains "$output" "must be milliseconds" || fail "output: $output"
}

# Both scripts route through the helper; a direct `export …=NNN` would silently
# reintroduce the dead workflow env and the bound race.
@test "both maestro scripts take the value from the helper, not a literal export" {
  for s in ios android; do
    f="$REPO_ROOT/scripts/e2e/$s-maestro.sh"
    grep -q 'workflows_driver_startup_timeout' "$f" || fail "$s-maestro.sh does not call the helper"
    ! grep -qE '^export MAESTRO_DRIVER_STARTUP_TIMEOUT=[0-9]' "$f" || fail "$s-maestro.sh still hardcodes the timeout"
  done
}

@test "check-e2e.yml passes the iOS suite a value below the default bound" {
  v=$(grep -A4 "name: Maestro suite (iOS)" "$REPO_ROOT/.github/workflows/check-e2e.yml" | grep -oE "MAESTRO_DRIVER_STARTUP_TIMEOUT: '[0-9]+'" | grep -oE '[0-9]+')
  [ -n "$v" ] || fail "no MAESTRO_DRIVER_STARTUP_TIMEOUT on the iOS suite step"
  [ "$v" -lt 600000 ] || fail "check-e2e.yml sets $v, not below the 10-minute bound"
}
