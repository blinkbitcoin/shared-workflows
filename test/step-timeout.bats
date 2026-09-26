#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/step-timeout.sh: the E2E step's `timeout-minutes`, published as
# the suite bound plus a margin. A wrong answer either kills a healthy suite or
# never bounds a hung one. Covered here: the sum, the defaults, a margin of
# zero, an empty value falling back to the default, both refusals (suite bound
# and margin, non-numeric and negative), and standard output as the channel
# when there is no GITHUB_OUTPUT.

load test_helper

setup() {
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : > "$GITHUB_OUTPUT"
  export GITHUB_OUTPUT
}

@test "the step bound is the suite bound plus the margin" {
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=20 WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES=5 \
    run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "minutes=25" ] || fail "wrong bound: $output"
}

@test "the step bound defaults leave room for teardown" {
  # The step must outlast the suite, or a suite that hits its own bound is
  # killed by the step first and its forensics never run.
  run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "minutes=15" ] || fail "expected the 10+5 default: $output"
}

@test "a non-numeric timeout is refused rather than read as zero" {
  # Bash reads 'abc' as 0 in arithmetic, which would publish a bound of 5 and
  # kill every suite. Both variables are checked.
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=abc run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -ne 0 ] || fail "must refuse a non-numeric suite timeout: $output"
  contains "$output" "WORKFLOWS_SUITE_TIMEOUT_MINUTES" || fail "$output"

  WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES=-1 run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -ne 0 ] || fail "must refuse a negative margin: $output"
  contains "$output" "WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES" || fail "$output"
}

@test "a negative suite timeout is refused as an error annotation that quotes the value" {
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=-5 run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::WORKFLOWS_SUITE_TIMEOUT_MINUTES must be a non-negative integer (got '-5')" ||
    fail "the refusal does not quote the value: $output"
}

@test "a non-numeric margin is refused as an error annotation that quotes the value" {
  WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES=five run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES must be a non-negative integer (got 'five')" ||
    fail "the refusal does not quote the value: $output"
}

@test "a refused value publishes no bound at all" {
  # A half-written output would still reach `fromJSON(...)` in the workflow.
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=10m run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a bound was published after a refusal: $(cat "$GITHUB_OUTPUT")"
}

@test "a margin of zero is accepted and the bound is the suite bound itself" {
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=20 WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES=0 \
    run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 0 ] || fail "zero is a non-negative integer: $status $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "minutes=20" ] || fail "wrong bound: $output"
}

@test "an empty timeout or margin falls back to its default rather than being refused" {
  # The workflow passes an input through even when the caller left it empty;
  # the empty string takes the default before the integer check sees it.
  WORKFLOWS_SUITE_TIMEOUT_MINUTES="" WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES="" \
    run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 0 ] || fail "an empty value must take the default: $status $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "minutes=15" ] || fail "expected the 10+5 default: $output"
}

@test "without GITHUB_OUTPUT the bound is printed on standard output" {
  # A local run has no GITHUB_OUTPUT; the answer must still be visible.
  unset GITHUB_OUTPUT
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=30 run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "minutes=35" ] || fail "expected the bound on standard output: $output"
}
