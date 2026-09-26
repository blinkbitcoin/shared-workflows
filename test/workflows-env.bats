#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/workflows-env.sh: the `setup` composite action (and check-e2e.yml's
# build-ios job, as its first step) publishes WORKFLOWS_DIR and
# WORKING_DIRECTORY into $GITHUB_ENV and keeps the `.workflows/` checkout out of
# the consumer's git status. A wrong WORKFLOWS_DIR makes every later
# `bash "$WORKFLOWS_DIR/..."` exit 127.
#
# Covers: both variables published, with the working directory defaulting to
# `.`; the git exclude entry written exactly once and without clobbering what
# was there; the exclude still written when there is no $GITHUB_ENV; and fatal
# without GITHUB_WORKSPACE or with a working directory that does not exist.

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
}

@test "WORKFLOWS_DIR is published beside the workspace, not inside the consumer" {
  run bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKFLOWS_DIR=$GITHUB_WORKSPACE/.workflows" || fail "wrong WORKFLOWS_DIR: $output"
  contains "$output" "WORKING_DIRECTORY=consumer" || fail "working directory not carried: $output"
}

@test "WORKING_DIRECTORY defaults to the workspace root when unset" {
  unset WORKING_DIRECTORY
  run bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKING_DIRECTORY=." || fail "wrong default: $output"
}

@test "the consumer's git exclude gains .workflows/ exactly once" {
  # Appending on every job would grow the file without bound; the guard is a
  # grep, and a grep that stops matching is invisible.
  bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  run grep -c '^\.workflows/$' "$CONSUMER/.git/info/exclude"
  [ "$output" = "1" ] || fail "expected one entry, found $output"
}

@test "an existing exclude file keeps what it already had" {
  mkdir -p "$CONSUMER/.git/info"
  printf 'node_modules/\n' > "$CONSUMER/.git/info/exclude"
  bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  run cat "$CONSUMER/.git/info/exclude"
  contains "$output" "node_modules/" || fail "it clobbered the consumer's own excludes: $output"
  contains "$output" ".workflows/" || fail "$output"
}

@test "without GITHUB_ENV nothing is written there, and the exclude is still written" {
  unset GITHUB_ENV
  run bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "printed something where nothing was expected: $output"
  run cat "$BATS_TEST_TMPDIR/env"
  [ -z "$output" ] || fail "wrote to a file nobody named: $output"
  run grep -c '^\.workflows/$' "$CONSUMER/.git/info/exclude"
  [ "$output" = "1" ] || fail "the exclude entry was not written: $output"
}

@test "without GITHUB_WORKSPACE it fails rather than publish a relative WORKFLOWS_DIR" {
  unset GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  [ "$status" -ne 0 ] || fail "an unset workspace must be fatal: $output"
  contains "$output" "GITHUB_WORKSPACE" || fail "does not name the variable: $output"
  run cat "$GITHUB_ENV"
  not_contains "$output" "WORKFLOWS_DIR=" || fail "published WORKFLOWS_DIR anyway: $output"
}

@test "a working directory that does not exist is fatal and creates no exclude" {
  WORKING_DIRECTORY="no-such-directory" run bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  [ "$status" -ne 0 ] || fail "a missing working directory must be fatal: $output"
  contains "$output" "no-such-directory" || fail "does not name the directory: $output"
  [ ! -e "$GITHUB_WORKSPACE/no-such-directory" ] || fail "it created the missing working directory"
}
