#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/shared-env.sh: the part of the env contract that e2e-env.sh and
# release-env.sh share. Covered here: the WORKFLOWS_OUT default (under
# RUNNER_TEMP, /tmp without it, an explicit value kept) and its export;
# WORKFLOWS_LIB_DIR, absolute and exported, wherever the caller stands; that
# sourcing it creates nothing and publishes nothing; workflows_out_init
# creating the directory and publishing it once across processes, and with no
# GITHUB_ENV; and workflows_platform from an argument, from WORKFLOWS_PLATFORM,
# the argument winning, and its refusal of anything else or nothing.
load test_helper

setup() {
  GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
  export GITHUB_ENV
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  unset WORKFLOWS_OUT WORKFLOWS_PLATFORM WORKFLOWS_LIB_DIR
}

# shared_env COMMANDS - runs COMMANDS in a fresh bash that has sourced common.sh
# and this library, under the options every caller sets.
shared_env() {
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/shared-env.sh"; eval "$2"' _ "$REPO_ROOT" "$1"
}

# --- WORKFLOWS_OUT and WORKFLOWS_LIB_DIR ----------------------------------------

@test "WORKFLOWS_OUT defaults to a folder under RUNNER_TEMP, and reaches child processes" {
  shared_env 'bash -c "printf \"%s\\n\" \"\$WORKFLOWS_OUT\""'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "$RUNNER_TEMP/workflows" ] || fail "got '$output'"
}

@test "with no RUNNER_TEMP WORKFLOWS_OUT falls back to /tmp/workflows" {
  unset RUNNER_TEMP
  shared_env 'printf "%s\n" "$WORKFLOWS_OUT"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "/tmp/workflows" ] || fail "got '$output'"
}

@test "a set WORKFLOWS_OUT keeps its value" {
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/mine" shared_env 'printf "%s\n" "$WORKFLOWS_OUT"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "$BATS_TEST_TMPDIR/mine" ] || fail "got '$output'"
}

@test "WORKFLOWS_LIB_DIR is scripts/lib, absolute, from wherever the caller stands, and is exported" {
  # Sourced by a relative path, then read after moving away from it.
  run bash -c 'set -euo pipefail
    source "$1/scripts/lib/common.sh"
    cd "$1/scripts"
    source lib/shared-env.sh
    cd "$2"
    bash -c "printf \"%s\\n\" \"\$WORKFLOWS_LIB_DIR\""' _ "$REPO_ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "$(cd "$REPO_ROOT/scripts/lib" && pwd)" ] || fail "got '$output'"
}

@test "sourcing it creates nothing and publishes nothing" {
  shared_env 'true'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -e "$RUNNER_TEMP/workflows" ] || fail "sourcing the library created the output directory"
  [ ! -s "$GITHUB_ENV" ] || fail "sourcing the library published: $(cat "$GITHUB_ENV")"
}

# --- workflows_out_init ----------------------------------------------------------

@test "workflows_out_init creates WORKFLOWS_OUT and publishes it once, across processes" {
  shared_env 'workflows_out_init; workflows_out_init'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  shared_env 'workflows_out_init'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -d "$RUNNER_TEMP/workflows" ] || fail "the output directory was not created"
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ] || fail "published other than once: $(cat "$GITHUB_ENV")"
  grep -qxF "WORKFLOWS_OUT=$RUNNER_TEMP/workflows" "$GITHUB_ENV" || fail "published: $(cat "$GITHUB_ENV")"
}

@test "with no GITHUB_ENV workflows_out_init still creates the directory" {
  unset GITHUB_ENV
  shared_env 'workflows_out_init'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -d "$RUNNER_TEMP/workflows" ] || fail "the output directory was not created"
}

@test "workflows_out_init stops the caller when the directory cannot be made" {
  mkdir -p "$RUNNER_TEMP"
  : > "$RUNNER_TEMP/workflows"
  shared_env 'workflows_out_init; echo reached'
  [ "$status" -ne 0 ] || fail "a file in the way was accepted: $output"
  not_contains "$output" "reached" || fail "the caller carried on: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "a directory that does not exist was published: $(cat "$GITHUB_ENV")"
}

# --- workflows_platform ------------------------------------------------------------

@test "the platform comes from the argument, or from WORKFLOWS_PLATFORM when there is none" {
  local platform
  for platform in ios android; do
    shared_env "workflows_platform $platform"
    [ "$status" -eq 0 ] || fail "$platform: status $status: $output"
    [ "$output" = "$platform" ] || fail "$platform: got '$output'"
  done
  WORKFLOWS_PLATFORM=android shared_env 'workflows_platform'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "android" ] || fail "WORKFLOWS_PLATFORM was not used: $output"
  WORKFLOWS_PLATFORM=android shared_env 'workflows_platform ios'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "ios" ] || fail "the argument did not win: $output"
}

@test "a platform other than ios or android is fatal, names what it got and how to pass one" {
  shared_env 'workflows_platform windows'
  [ "$status" -ne 0 ] || fail "windows was accepted: $output"
  contains "$output" "platform must be ios or android (got 'windows'); pass it as \$1 or set WORKFLOWS_PLATFORM" || fail "output: $output"
}

@test "no platform at all is fatal" {
  shared_env 'workflows_platform'
  [ "$status" -ne 0 ] || fail "no platform was accepted: $output"
  contains "$output" "platform must be ios or android (got '')" || fail "output: $output"
}
