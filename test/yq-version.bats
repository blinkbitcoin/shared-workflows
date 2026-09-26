#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/yq-version.sh: the `native-key` composite action publishes the yq
# pin from scripts/lib/versions.sh as the step output `version`, so the yq it
# installs is the one this repository pins rather than whatever a runner image
# ships.
#
# Covers: the pin published to $GITHUB_OUTPUT; printed on stdout when there is
# no $GITHUB_OUTPUT; and fatal, publishing nothing, when the versions file is
# missing or no longer pins yq. The two failure cases run a copy of the script
# beside a doctored scripts/lib/, since scripts/ itself is never edited here.

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

# copy_scripts - lay out scripts/ci/yq-version.sh and scripts/lib/common.sh
# under $BATS_TEST_TMPDIR/scripts, without versions.sh; prints the copied
# script's path.
copy_scripts() {
  local copy="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$copy/ci" "$copy/lib"
  cp "$REPO_ROOT/scripts/ci/yq-version.sh" "$copy/ci/"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$copy/lib/"
  printf '%s\n' "$copy/ci/yq-version.sh"
}

@test "the yq pin comes from the one place versions are written down" {
  run bash "$REPO_ROOT/scripts/ci/yq-version.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local pinned
  pinned="$(sed -n 's/^export YQ_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/lib/versions.sh")"
  [ -n "$pinned" ] || fail "could not read YQ_VERSION from scripts/lib/versions.sh"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "version=$pinned" ] || fail "published '$output', versions.sh pins $pinned"
}

@test "without GITHUB_OUTPUT the pin is printed on stdout" {
  local pinned
  pinned="$(sed -n 's/^export YQ_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/lib/versions.sh")"
  unset GITHUB_OUTPUT
  run bash "$REPO_ROOT/scripts/ci/yq-version.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "version=$pinned" ] || fail "wrong stdout: $output"
}

@test "a missing versions file is fatal rather than an empty pin" {
  local script
  script="$(copy_scripts)"
  run bash "$script"
  [ "$status" -ne 0 ] || fail "a missing versions file must be fatal: $output"
  contains "$output" "versions.sh" || fail "does not name the missing file: $output"
  run cat "$GITHUB_OUTPUT"
  [ -z "$output" ] || fail "it published something anyway: $output"
}

@test "a versions file that no longer pins yq is fatal rather than an empty pin" {
  local script
  script="$(copy_scripts)"
  grep -v '^export YQ_VERSION=' "$REPO_ROOT/scripts/lib/versions.sh" > "$BATS_TEST_TMPDIR/scripts/lib/versions.sh"
  run bash "$script"
  [ "$status" -ne 0 ] || fail "a missing yq pin must be fatal: $output"
  contains "$output" "YQ_VERSION" || fail "does not name the variable: $output"
  run cat "$GITHUB_OUTPUT"
  [ -z "$output" ] || fail "it published something anyway: $output"
}
