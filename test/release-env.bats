#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/release-env.sh: the library every release and OTA script sources
# after common.sh. Sourcing it derives the five staging directories from one
# root, creates the root and publishes each directory to $GITHUB_ENV once; it
# also defines workflows_release_platform and workflows_fingerprint.
#
# Covered here: the directory defaults (under RUNNER_TEMP, and /tmp without it),
# each override, publishing once and not over an earlier step's value, no
# GITHUB_ENV at all, the platform from an argument or from WORKFLOWS_PLATFORM and
# its refusal, and every path through workflows_fingerprint: a value passed down,
# JSON and bare-hash output, a failing CLI, output with no hash, no npx, no yq,
# and a working directory that does not exist.

load test_helper

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_ENV"
  export GITHUB_ENV
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export WORKFLOWS_TEST_CALLS="$CALLS"
  # Whatever the calling shell has set would otherwise decide these cases.
  unset WORKFLOWS_OUT WORKFLOWS_OUTPUT_DIR WORKFLOWS_RELEASE_META_DIR WORKFLOWS_OTA_DIR WORKFLOWS_ASSETS_DIR
  unset WORKFLOWS_PLATFORM WORKFLOWS_FINGERPRINT_IOS WORKFLOWS_FINGERPRINT_ANDROID
}

# release_env COMMANDS - runs COMMANDS in a fresh bash that has sourced common.sh
# and then this library, under the shell options every script that sources it
# sets.
release_env() {
  bash -c 'set -euo pipefail; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/release-env.sh"; eval "$2"' _ "$REPO_ROOT" "$1"
}

# A fake npx standing in for the consumer's @expo/fingerprint bin. It records
# its directory and arguments, prints $WORKFLOWS_TEST_FINGERPRINT_OUTPUT and
# exits with $WORKFLOWS_TEST_FINGERPRINT_STATUS (default 0).
stub_npx() {
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$WORKFLOWS_TEST_CALLS"
printf '%s' "${WORKFLOWS_TEST_FINGERPRINT_OUTPUT:-}"
exit "${WORKFLOWS_TEST_FINGERPRINT_STATUS:-0}"
SH
  chmod +x "$STUB/npx"
  export PATH="$STUB:$PATH"
}

# Prints a directory holding only bash, mkdir, grep and the named tools, for a
# PATH on which a tool installed on this machine cannot satisfy the lookup a
# case is about.
bare_path() {
  local dir="$BATS_TEST_TMPDIR/bare" tool
  mkdir -p "$dir"
  for tool in bash mkdir grep "$@"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# --- the staging directories ------------------------------------------------

@test "release-env publishes the release directories and derives them from one root" {
  run bash -c 'set -e; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/release-env.sh"; printf "%s\n%s\n" "$WORKFLOWS_OUT" "$WORKFLOWS_ASSETS_DIR"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ] || fail "sourcing it failed: $output"
  contains "$output" "$RUNNER_TEMP" || fail "the output root is not the runner temp: $output"
}

@test "every directory defaults to a folder under RUNNER_TEMP, and the root is created" {
  run release_env 'printf "%s\n" "$WORKFLOWS_OUT" "$WORKFLOWS_OUTPUT_DIR" "$WORKFLOWS_RELEASE_META_DIR" "$WORKFLOWS_OTA_DIR" "$WORKFLOWS_ASSETS_DIR"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local root="$RUNNER_TEMP/workflows"
  [ "$output" = "$root
$root
$root/release-meta
$root/ota
$root/assets" ] || fail "unexpected directories: $output"
  [ -d "$root" ] || fail "the root was not created"
}

@test "with no RUNNER_TEMP the root falls back to /tmp/workflows" {
  unset RUNNER_TEMP
  run release_env 'printf "%s\n" "$WORKFLOWS_OUT" "$WORKFLOWS_ASSETS_DIR"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "/tmp/workflows
/tmp/workflows/assets" ] || fail "unexpected directories: $output"
}

@test "WORKFLOWS_OUT moves every directory that is not set on its own" {
  local root="$BATS_TEST_TMPDIR/elsewhere"
  WORKFLOWS_OUT="$root" run release_env 'printf "%s\n" "$WORKFLOWS_OUTPUT_DIR" "$WORKFLOWS_RELEASE_META_DIR" "$WORKFLOWS_OTA_DIR" "$WORKFLOWS_ASSETS_DIR"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "$root
$root/release-meta
$root/ota
$root/assets" ] || fail "the directories did not follow WORKFLOWS_OUT: $output"
  [ -d "$root" ] || fail "the configured root was not created"
}

@test "a directory set on its own keeps its value" {
  WORKFLOWS_OUTPUT_DIR=/set/output WORKFLOWS_RELEASE_META_DIR=/set/meta \
    WORKFLOWS_OTA_DIR=/set/ota WORKFLOWS_ASSETS_DIR=/set/assets \
    run release_env 'printf "%s\n" "$WORKFLOWS_OUTPUT_DIR" "$WORKFLOWS_RELEASE_META_DIR" "$WORKFLOWS_OTA_DIR" "$WORKFLOWS_ASSETS_DIR"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "/set/output
/set/meta
/set/ota
/set/assets" ] || fail "an override was replaced: $output"
}

@test "each directory is published to GITHUB_ENV once, however many scripts source the library" {
  # Every step in a job is its own process; the guard is the file itself.
  release_env 'true'
  release_env 'true'
  local name count
  for name in WORKFLOWS_OUT WORKFLOWS_OUTPUT_DIR WORKFLOWS_RELEASE_META_DIR WORKFLOWS_OTA_DIR WORKFLOWS_ASSETS_DIR; do
    count="$(grep -c "^$name=" "$GITHUB_ENV" || true)"
    [ "$count" -eq 1 ] || fail "$name was published $count times: $(cat "$GITHUB_ENV")"
  done
  run grep "^WORKFLOWS_ASSETS_DIR=" "$GITHUB_ENV"
  [ "$output" = "WORKFLOWS_ASSETS_DIR=$RUNNER_TEMP/workflows/assets" ] || fail "wrong published value: $output"
}

@test "a value an earlier step already published is not written again" {
  printf 'WORKFLOWS_OUT=/earlier\nWORKFLOWS_OTA_DIR<<EOF\n/earlier/ota\nEOF\n' > "$GITHUB_ENV"
  run release_env 'true'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run grep -c "^WORKFLOWS_OUT[=<]" "$GITHUB_ENV"
  [ "$output" = "1" ] || fail "WORKFLOWS_OUT was published a second time: $(cat "$GITHUB_ENV")"
  run grep -c "^WORKFLOWS_OTA_DIR[=<]" "$GITHUB_ENV"
  [ "$output" = "1" ] || fail "a multi-line entry was not recognised: $(cat "$GITHUB_ENV")"
  run grep -c "^WORKFLOWS_ASSETS_DIR=" "$GITHUB_ENV"
  [ "$output" = "1" ] || fail "a directory not yet published was skipped: $(cat "$GITHUB_ENV")"
}

@test "with no GITHUB_ENV nothing is written, and the directories still reach child processes" {
  unset GITHUB_ENV
  run release_env 'bash -c "printf \"%s\n\" \"\$WORKFLOWS_OUT\" \"\$WORKFLOWS_ASSETS_DIR\""'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "$RUNNER_TEMP/workflows
$RUNNER_TEMP/workflows/assets" ] || fail "the directories were not exported: $output"
  [ ! -s "$BATS_TEST_TMPDIR/env" ] || fail "wrote to an environment file nobody named: $(cat "$BATS_TEST_TMPDIR/env")"
}

# --- workflows_release_platform ------------------------------------------------

@test "the platform comes from the argument, or from WORKFLOWS_PLATFORM when there is none" {
  run release_env 'workflows_release_platform ios; workflows_release_platform android'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "ios
android" ] || fail "an argument was not returned as given: $output"

  WORKFLOWS_PLATFORM=android run release_env 'workflows_release_platform'
  [ "$output" = "android" ] || fail "WORKFLOWS_PLATFORM was not used: $output"

  WORKFLOWS_PLATFORM=android run release_env 'workflows_release_platform ios'
  [ "$output" = "ios" ] || fail "the argument must win over WORKFLOWS_PLATFORM: $output"
}

@test "a platform other than ios or android is fatal and names what it got" {
  run release_env 'workflows_release_platform windows'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::platform must be ios or android (got 'windows')" || fail "unexpected message: $output"
}

@test "no platform at all is fatal" {
  run release_env 'workflows_release_platform'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "(got '')" || fail "unexpected message: $output"
}

# --- workflows_fingerprint ------------------------------------------------------

@test "a fingerprint passed down from an earlier step is used without running the CLI" {
  stub_npx
  WORKFLOWS_FINGERPRINT_IOS=ios-passed WORKFLOWS_FINGERPRINT_ANDROID=android-passed \
    run release_env 'workflows_fingerprint ios; workflows_fingerprint android'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "ios-passed
android-passed" ] || fail "the passed-down values were not used: $output"
  [ ! -s "$CALLS" ] || fail "the CLI ran anyway: $(cat "$CALLS")"
}

@test "the CLI runs in the consumer root from the consumer's own bin, and its JSON hash is read" {
  stub_npx
  # The iOS value must not answer for Android.
  WORKFLOWS_FINGERPRINT_IOS=ios-passed WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":"abc123","sources":[]}' \
    run release_env 'workflows_fingerprint android'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "abc123" ] || fail "the hash was not read out of the JSON: $output"
  run cat "$CALLS"
  [ "$output" = "$(cd "$CONSUMER" && pwd -P)|--no fingerprint fingerprint:generate --platform android" ] \
    || fail "wrong directory or arguments: $output"
}

@test "the platform for the fingerprint may come from WORKFLOWS_PLATFORM" {
  stub_npx
  WORKFLOWS_PLATFORM=ios WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":"fromenv"}' run release_env 'workflows_fingerprint'
  [ "$output" = "fromenv" ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "--platform ios" || fail "the platform was not passed on: $output"
}

@test "a bare hash from an older CLI is read with its whitespace removed" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT=$'  bare111\n\n' run release_env 'workflows_fingerprint ios'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "bare111" ] || fail "the bare hash was not read: $output"
}

@test "a failing fingerprint CLI is fatal and points at the missing devDependency" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_STATUS=1 run release_env 'workflows_fingerprint ios'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::fingerprint:generate failed for ios" || fail "unexpected message: $output"
  contains "$output" "@expo/fingerprint a devDependency" || fail "does not say what is likely missing: $output"
}

@test "JSON output with no hash in it is fatal" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"sources":[]}' run release_env 'workflows_fingerprint android'
  [ "$status" -eq 1 ] || fail "an empty hash must not be returned: $output"
  contains "$output" "::error::could not read a fingerprint hash for android" || fail "unexpected message: $output"
}

@test "empty output from the CLI is fatal" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT=$' \n' run release_env 'workflows_fingerprint ios'
  [ "$status" -eq 1 ] || fail "an empty hash must not be returned: $output"
  contains "$output" "::error::could not read a fingerprint hash for ios" || fail "unexpected message: $output"
}

@test "an unknown platform stops the fingerprint before the CLI runs" {
  stub_npx
  run release_env 'workflows_fingerprint windows'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "platform must be ios or android (got 'windows')" || fail "unexpected message: $output"
  [ ! -s "$CALLS" ] || fail "the CLI ran anyway: $(cat "$CALLS")"
}

# Every caller reads the fingerprint through `$(...)`, where `set -e` does not
# reach: a failed step inside it used to be ignored, and the CLI then ran with
# an empty platform or from whatever directory the step started in.
@test "read through \$(...), an unknown platform still stops before the CLI runs" {
  stub_npx
  run release_env 'fp="$(workflows_fingerprint windows)"; echo "reached with fp=$fp"'
  [ "$status" -ne 0 ] || fail "the caller carried on: $output"
  contains "$output" "platform must be ios or android (got 'windows')" || fail "unexpected message: $output"
  not_contains "$output" "reached with" || fail "the caller carried on: $output"
  [ ! -s "$CALLS" ] || fail "the CLI ran anyway: $(cat "$CALLS")"
}

@test "read through \$(...), a working directory that does not exist stops before the CLI runs" {
  stub_npx
  export WORKFLOWS_TEST_FINGERPRINT_OUTPUT=abc
  WORKING_DIRECTORY=missing run release_env 'fp="$(workflows_fingerprint ios)"; echo "reached with fp=$fp"'
  [ "$status" -ne 0 ] || fail "the caller carried on: $output"
  not_contains "$output" "reached with" || fail "the caller carried on: $output"
  [ ! -s "$CALLS" ] || fail "the CLI ran from the wrong directory: $(cat "$CALLS")"
}

@test "no npx on PATH names the missing command" {
  PATH="$(bare_path)" run release_env 'workflows_fingerprint ios'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: npx" || fail "does not name the missing command: $output"
}

@test "JSON output with no yq on PATH names the missing command" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":"abc123"}' PATH="$(bare_path npx)" run release_env 'workflows_fingerprint ios'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: yq" || fail "does not name the missing command: $output"
}

@test "a working directory that does not exist stops the fingerprint before the CLI runs" {
  stub_npx
  WORKING_DIRECTORY="no-such-directory" run release_env 'workflows_fingerprint ios'
  [ "$status" -ne 0 ] || fail "a fingerprint of the wrong directory must not be returned: $output"
  [ ! -s "$CALLS" ] || fail "the CLI ran anyway: $(cat "$CALLS")"
}
