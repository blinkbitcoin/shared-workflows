#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/env-publish.sh: publishes WORKFLOWS_OUT and WORKFLOWS_RUN_START
# to $GITHUB_ENV so a later `with:` block can use them before any other E2E
# script has run. If it stops publishing, those resolve to empty and an upload
# silently finds nothing. Covered here: the published values and their
# defaults, a caller-set output directory, the run-start stamp, the log lines,
# publishing once per job, a local run with no GITHUB_ENV, and an output
# directory that cannot be created.
#
# scripts/release/env-publish.sh shares the name; its test is
# release-env-publish.bats.

load test_helper

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"
  export GITHUB_OUTPUT GITHUB_ENV
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
}

@test "the e2e env-publish puts the output dir and run start in the environment" {
  # It exists so a later `with:` block can use ${{ env.WORKFLOWS_OUT }} before any
  # other script in the family has run. If it stops publishing, those resolve
  # to empty and an upload silently finds nothing.
  run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKFLOWS_OUT=" || fail "$output"
  contains "$output" "WORKFLOWS_RUN_START=" || fail "$output"
}

@test "the output directory defaults to one under the runner's temporary directory, with the run-start stamp in it" {
  run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  [ "$output" = "WORKFLOWS_OUT=$RUNNER_TEMP/workflows
WORKFLOWS_RUN_START=$RUNNER_TEMP/workflows/run-start" ] || fail "unexpected environment file: $output"
  [ -d "$RUNNER_TEMP/workflows" ] || fail "the output directory was not created"
  [ -f "$RUNNER_TEMP/workflows/run-start" ] || fail "the run-start stamp was not created"
}

@test "an output directory the caller set is published as given" {
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/custom" run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKFLOWS_OUT=$BATS_TEST_TMPDIR/custom" || fail "the caller's directory was not published: $output"
  contains "$output" "WORKFLOWS_RUN_START=$BATS_TEST_TMPDIR/custom/run-start" || fail "the stamp is not in the caller's directory: $output"
}

@test "it logs both values, so the run log shows where the artifacts go" {
  run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "WORKFLOWS_OUT=$RUNNER_TEMP/workflows" || fail "the output directory is not logged: $output"
  contains "$output" "WORKFLOWS_RUN_START=$RUNNER_TEMP/workflows/run-start" || fail "the stamp is not logged: $output"
}

@test "a second run in the same job publishes each value once" {
  bash "$REPO_ROOT/scripts/e2e/env-publish.sh" 2>/dev/null
  run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "a second run must succeed: $status $output"
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ] || fail "WORKFLOWS_OUT published twice: $(cat "$GITHUB_ENV")"
  [ "$(grep -c '^WORKFLOWS_RUN_START=' "$GITHUB_ENV")" -eq 1 ] || fail "WORKFLOWS_RUN_START published twice: $(cat "$GITHUB_ENV")"
}

@test "without GITHUB_ENV a local run still succeeds and logs the values" {
  unset GITHUB_ENV
  run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "a local run must succeed: $status $output"
  contains "$output" "WORKFLOWS_OUT=$RUNNER_TEMP/workflows" || fail "the output directory is not logged: $output"
  [ ! -s "$BATS_TEST_TMPDIR/env" ] || fail "wrote an environment file nobody named: $(cat "$BATS_TEST_TMPDIR/env")"
}

@test "an output directory that cannot be created fails the step and publishes nothing" {
  : > "$BATS_TEST_TMPDIR/a-file"
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/a-file/workflows" run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -ne 0 ] || fail "an uncreatable output directory must fail: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "published a directory that does not exist: $(cat "$GITHUB_ENV")"
}
