#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/e2e-maestro.sh: the Maestro policy of the E2E env contract, which
# scripts/lib/e2e-env.sh sources for both maestro scripts, so the two platforms
# cannot drift apart on it. Covered here: the defaults and their overrides,
# that sourcing it creates nothing, workflows_driver_startup_timeout (default,
# override, the bound and what moves it, a non-numeric value, no argument) and
# workflows_assert_suite_ran (zero flows, the tag filters named, flows that ran,
# failing flows left to Maestro, no report, a report without a count).
#
# MAESTRO_DRIVER_STARTUP_TIMEOUT must be strictly below the suite bound. Maestro
# throws a real exception when it expires, which the maestro scripts rerun once;
# a value at or above the bound means the bound's exit 124 - never retried -
# fires first, and a driver that failed to launch costs the whole bound with
# zero flows run (run 35259139324: ten minutes, TEST EXECUTE FAILED at 77s).
#
# Maestro exits 0 when its flow selection matches nothing at all: a tag filter no
# flow carries, a renamed flows directory, a config.yaml whose includeTags
# stopped matching. The E2E job then went green having tested nothing, which is
# the most expensive kind of pass - indistinguishable from a real one, and it
# stays green until someone ships a broken build. workflows_assert_suite_ran
# reads the count out of the junit report Maestro already writes, so nothing
# extra runs.
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/ghenv"
  : > "$GITHUB_ENV"
  mkdir -p "$WORKFLOWS_OUT"
  unset MAESTRO_DRIVER_STARTUP_TIMEOUT WORKFLOWS_SUITE_TIMEOUT_MINUTES WORKFLOWS_MAESTRO_FLOWS
  unset WORKFLOWS_MAESTRO_INCLUDE_TAGS WORKFLOWS_MAESTRO_EXCLUDE_TAGS
  JUNIT="$WORKFLOWS_OUT/junit.xml"
}

# maestro_env COMMANDS - runs COMMANDS in a fresh bash that has sourced
# common.sh and this library, under the options every caller sets.
maestro_env() {
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/e2e-maestro.sh"; eval "$2"' _ "$REPO_ROOT" "$1"
}

# --- the defaults ------------------------------------------------------------

@test "the flows directory and the suite bound default, and reach child processes" {
  maestro_env 'bash -c "printf \"%s|%s\\n\" \"\$WORKFLOWS_MAESTRO_FLOWS\" \"\$WORKFLOWS_SUITE_TIMEOUT_MINUTES\""'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = ".maestro|10" ] || fail "got '$output'"
}

@test "a set flows directory and suite bound keep their values" {
  WORKFLOWS_MAESTRO_FLOWS=e2e/flows WORKFLOWS_SUITE_TIMEOUT_MINUTES=7 \
    maestro_env 'printf "%s|%s\n" "$WORKFLOWS_MAESTRO_FLOWS" "$WORKFLOWS_SUITE_TIMEOUT_MINUTES"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "e2e/flows|7" ] || fail "got '$output'"
}

@test "sourcing it creates nothing and publishes nothing" {
  rm -rf "$WORKFLOWS_OUT"
  maestro_env 'true'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -e "$WORKFLOWS_OUT" ] || fail "sourcing the library created $WORKFLOWS_OUT"
  [ ! -s "$GITHUB_ENV" ] || fail "sourcing the library published: $(cat "$GITHUB_ENV")"
}

# --- workflows_driver_startup_timeout ----------------------------------------

timeout_for() { # DEFAULT_MS, with the caller's environment
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-maestro.sh'; workflows_driver_startup_timeout $1"
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

@test "with no default the timeout is refused, with the usage" {
  # A failed `${1:?}` ends the shell with 127, which bats reads as a missing
  # command; the subshell turns it into a plain failure.
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-maestro.sh'; (workflows_driver_startup_timeout) || exit 1"
  [ "$status" -ne 0 ] || fail "no default was accepted: $output"
  contains "$output" "usage: workflows_driver_startup_timeout DEFAULT_MS" || fail "output: $output"
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

@test "test-e2e.yml passes the iOS suite a value below the default bound" {
  v=$(grep -A4 "name: Maestro suite (iOS)" "$REPO_ROOT/.github/workflows/test-e2e.yml" | grep -oE "MAESTRO_DRIVER_STARTUP_TIMEOUT: '[0-9]+'" | grep -oE '[0-9]+')
  [ -n "$v" ] || fail "no MAESTRO_DRIVER_STARTUP_TIMEOUT on the iOS suite step"
  [ "$v" -lt 600000 ] || fail "test-e2e.yml sets $v, not below the 10-minute bound"
}

# --- workflows_assert_suite_ran ----------------------------------------------

# Runs the assertion in a subshell that sources the library the way the maestro
# scripts do.
assert_ran() {
  run bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/e2e-maestro.sh"
    workflows_assert_suite_ran "$2" "$3"
  ' _ "$REPO_ROOT" "$1" "${2:-iOS}"
}

write_junit() {
  cat > "$JUNIT" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Test Suite" tests="$1" failures="$2" time="1.0">
  </testsuite>
</testsuites>
XML
}

@test "a suite that ran zero flows is a failure, not a pass" {
  write_junit 0 0
  assert_ran "$JUNIT"
  [ "$status" -ne 0 ] || fail "a suite that ran nothing passed: $output"
  contains "$output" "ran 0 flows" || fail "the error does not say the suite was empty: $output"
}

@test "the zero-flow error names the tag filters, which are the usual cause" {
  write_junit 0 0
  run bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/e2e-maestro.sh"
    WORKFLOWS_MAESTRO_INCLUDE_TAGS=smoke WORKFLOWS_MAESTRO_EXCLUDE_TAGS=slow workflows_assert_suite_ran "$2" iOS
  ' _ "$REPO_ROOT" "$JUNIT"
  [ "$status" -ne 0 ] || fail "expected a failure: $output"
  contains "$output" "WORKFLOWS_MAESTRO_INCLUDE_TAGS='smoke'" || fail "the error does not name the include tag: $output"
  contains "$output" "WORKFLOWS_MAESTRO_EXCLUDE_TAGS='slow'" || fail "the error does not name the exclude tag: $output"
}

@test "a suite that ran flows passes and says how many" {
  write_junit 4 0
  assert_ran "$JUNIT" Android
  [ "$status" -eq 0 ] || fail "a real suite was rejected: $output"
  contains "$output" "Android: Maestro ran 4 flow" || fail "the count is not reported: $output"
}

@test "a single flow is enough" {
  write_junit 1 0
  assert_ran "$JUNIT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
}

# Maestro's own exit status already covers failing flows; this guard is only
# about whether the suite existed. A report with failures still reaches here
# only when Maestro exited 0, but it must not be rejected by this check.
@test "the guard does not second-guess Maestro on failing flows" {
  write_junit 3 2
  assert_ran "$JUNIT"
  [ "$status" -eq 0 ] || fail "the guard rejected a suite that did run: $output"
}

@test "no junit report at all is a failure" {
  # Success with no report means nothing can show the suite ran, which is the
  # same hole by another route.
  assert_ran "$WORKFLOWS_OUT/does-not-exist.xml"
  [ "$status" -ne 0 ] || fail "a missing report passed: $output"
  contains "$output" "no junit report" || fail "unexpected message: $output"
}

@test "a junit report with no tests= attribute is a failure" {
  printf '<?xml version="1.0"?>\n<testsuites></testsuites>\n' > "$JUNIT"
  assert_ran "$JUNIT"
  [ "$status" -ne 0 ] || fail "an uncountable report passed: $output"
  contains "$output" "cannot confirm" || fail "unexpected message: $output"
}

@test "both platform scripts call the guard, and only on success" {
  for f in ios-maestro android-maestro; do
    path="$REPO_ROOT/scripts/e2e/$f.sh"
    grep -q 'workflows_assert_suite_ran' "$path" || fail "$f.sh does not assert the suite ran"
    # Gated on status 0: on a real failure Maestro's own status is the answer,
    # and an empty-report complaint would bury it.
    grep -qF 'if [ "$status" -eq 0 ]; then' "$path" \
      || fail "$f.sh calls the guard unconditionally; it must only run on success"
  done
}
