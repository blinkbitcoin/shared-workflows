#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/env-publish.sh: publishes WORKFLOWS_OUT and WORKFLOWS_RUN_START
# to $GITHUB_ENV so a later `with:` block can use them before any other E2E
# script has run. If it stops publishing, those resolve to empty and an upload
# silently finds nothing. Covered here: the published values and their
# defaults, a caller-set output directory, the run-start stamp, the log lines,
# publishing once per job, a local run with no GITHUB_ENV, an output directory
# that cannot be created, and WORKFLOWS_DIR - which it does not publish - unset
# (logged as not published yet), a directory (logged) and anything else (fails
# before publishing anything).
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
  # A runner that already ran the Setup action has it; each test sets its own.
  unset WORKFLOWS_DIR
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

@test "an unset WORKFLOWS_DIR passes and the log names the step that publishes it" {
  # The ios and android jobs run this before Setup, so unset is a normal case
  # here and must not fail.
  run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "an unset WORKFLOWS_DIR must pass: $status $output"
  contains "$output" "WORKFLOWS_DIR is not published yet" || fail "the log does not say WORKFLOWS_DIR is unpublished: $output"
  contains "$output" "publishes only the E2E output directory and run start" || fail "the log does not say what this step publishes: $output"
  contains "$output" '"Export WORKFLOWS_DIR environment"' || fail "the log does not name the step that publishes WORKFLOWS_DIR: $output"
  not_contains "$(cat "$GITHUB_ENV")" "WORKFLOWS_DIR=" || fail "published WORKFLOWS_DIR, which is not this step's: $(cat "$GITHUB_ENV")"
}

@test "a WORKFLOWS_DIR that is a directory passes and is logged" {
  # test-e2e.yml's build-ios publishes WORKFLOWS_DIR first, so this is its case.
  mkdir -p "$BATS_TEST_TMPDIR/.workflows"
  WORKFLOWS_DIR="$BATS_TEST_TMPDIR/.workflows" run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "a WORKFLOWS_DIR that is a directory must pass: $status $output"
  contains "$output" "WORKFLOWS_DIR=$BATS_TEST_TMPDIR/.workflows" || fail "WORKFLOWS_DIR is not logged: $output"
  not_contains "$output" "not published yet" || fail "logged a set WORKFLOWS_DIR as unpublished: $output"
  contains "$(cat "$GITHUB_ENV")" "WORKFLOWS_OUT=" || fail "the output directory was not published: $(cat "$GITHUB_ENV")"
}

@test "a WORKFLOWS_DIR that does not exist fails with the fix and publishes nothing" {
  WORKFLOWS_DIR="$BATS_TEST_TMPDIR/no-such-directory" run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 1 ] || fail "a missing WORKFLOWS_DIR must fail: $status $output"
  contains "$output" "::error::WORKFLOWS_DIR is '$BATS_TEST_TMPDIR/no-such-directory', which is not a directory" ||
    fail "no error annotation naming the value: $output"
  contains "$output" '%0AFix: WORKFLOWS_DIR belongs to scripts/ci/workflows-env.sh' || fail "the error carries no fix: $output"
  contains "$output" '"Publish WORKFLOWS_DIR"' || fail "the fix does not name test-e2e's own WORKFLOWS_DIR step: $output"
  contains "$output" 'consumer-guide.md#gotchas-encoded' || fail "the error does not link the guide: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "published values after a bad WORKFLOWS_DIR: $(cat "$GITHUB_ENV")"
  [ ! -e "$RUNNER_TEMP/workflows" ] || fail "created the output directory after a bad WORKFLOWS_DIR"
}

@test "a WORKFLOWS_DIR that is a file fails too" {
  : > "$BATS_TEST_TMPDIR/a-file"
  WORKFLOWS_DIR="$BATS_TEST_TMPDIR/a-file" run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 1 ] || fail "a WORKFLOWS_DIR that is a file must fail: $status $output"
  contains "$output" "which is not a directory" || fail "no error for a file: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "published values after a bad WORKFLOWS_DIR: $(cat "$GITHUB_ENV")"
}
