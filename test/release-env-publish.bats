#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/release/env-publish.sh: publishes the release directories
# (WORKFLOWS_OUT, WORKFLOWS_OUTPUT_DIR, WORKFLOWS_RELEASE_META_DIR,
# WORKFLOWS_OTA_DIR, WORKFLOWS_ASSETS_DIR) to $GITHUB_ENV so a later `with:`
# block can name them. Covered here: every directory published, each default
# and where it sits, a caller-set directory, the log lines, publishing once per
# job, a local run with no GITHUB_ENV, and an output directory that cannot be
# created.
#
# scripts/e2e/env-publish.sh shares the name; its test is e2e-env-publish.bats.

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

@test "the release env-publish puts every release directory in the environment" {
  run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  for name in WORKFLOWS_OUT WORKFLOWS_OUTPUT_DIR WORKFLOWS_RELEASE_META_DIR WORKFLOWS_OTA_DIR WORKFLOWS_ASSETS_DIR; do
    contains "$output" "$name=" || fail "$name was not published: $output"
  done
}

@test "the release directories sit under the output dir, not the consumer tree" {
  # A release directory inside the checkout would be collected by the
  # consumer's own tooling and show up as untracked files.
  bash "$REPO_ROOT/scripts/release/env-publish.sh"
  run cat "$GITHUB_ENV"
  not_contains "$output" "=$CONSUMER" || fail "a release dir is inside the consumer checkout: $output"
}

@test "each release directory defaults to its own folder under the output directory" {
  run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  local out="$RUNNER_TEMP/workflows"
  [ "$output" = "WORKFLOWS_OUT=$out
WORKFLOWS_OUTPUT_DIR=$out
WORKFLOWS_RELEASE_META_DIR=$out/release-meta
WORKFLOWS_OTA_DIR=$out/ota
WORKFLOWS_ASSETS_DIR=$out/assets" ] || fail "unexpected environment file: $output"
  [ -d "$out" ] || fail "the output directory was not created"
}

@test "a directory the caller set is published as given, and the rest follow the output directory" {
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/custom" WORKFLOWS_OTA_DIR="$BATS_TEST_TMPDIR/elsewhere/ota" \
    run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKFLOWS_OTA_DIR=$BATS_TEST_TMPDIR/elsewhere/ota" || fail "the caller's directory was not published: $output"
  contains "$output" "WORKFLOWS_RELEASE_META_DIR=$BATS_TEST_TMPDIR/custom/release-meta" ||
    fail "a default did not follow the caller's output directory: $output"
}

@test "it logs every directory it publishes" {
  run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  for name in WORKFLOWS_OUT WORKFLOWS_OUTPUT_DIR WORKFLOWS_RELEASE_META_DIR WORKFLOWS_OTA_DIR WORKFLOWS_ASSETS_DIR; do
    contains "$output" "$name=$RUNNER_TEMP/workflows" || fail "$name is not logged: $output"
  done
}

@test "a second run in the same job publishes each directory once" {
  bash "$REPO_ROOT/scripts/release/env-publish.sh" 2>/dev/null
  run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -eq 0 ] || fail "a second run must succeed: $status $output"
  for name in WORKFLOWS_OUT WORKFLOWS_OUTPUT_DIR WORKFLOWS_RELEASE_META_DIR WORKFLOWS_OTA_DIR WORKFLOWS_ASSETS_DIR; do
    [ "$(grep -c "^$name=" "$GITHUB_ENV")" -eq 1 ] || fail "$name published more than once: $(cat "$GITHUB_ENV")"
  done
}

@test "without GITHUB_ENV a local run still succeeds and logs the directories" {
  unset GITHUB_ENV
  run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -eq 0 ] || fail "a local run must succeed: $status $output"
  contains "$output" "WORKFLOWS_OTA_DIR=$RUNNER_TEMP/workflows/ota" || fail "the directories are not logged: $output"
  [ ! -s "$BATS_TEST_TMPDIR/env" ] || fail "wrote an environment file nobody named: $(cat "$BATS_TEST_TMPDIR/env")"
}

@test "an output directory that cannot be created fails the step and publishes nothing" {
  : > "$BATS_TEST_TMPDIR/a-file"
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/a-file/workflows" run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -ne 0 ] || fail "an uncreatable output directory must fail: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "published a directory that does not exist: $(cat "$GITHUB_ENV")"
}
