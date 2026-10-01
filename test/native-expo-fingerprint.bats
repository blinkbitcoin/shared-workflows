#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/expo/fingerprint.sh, the Expo stack's native fingerprint:
# @expo/fingerprint's `fingerprint:generate`, run through the consumer's own bin
# (`npx --no`) in the consumer root, its hash printed alone. A fake npx stands
# in for the CLI. Covered: JSON and bare-hash output, the platform from an
# argument or WORKFLOWS_PLATFORM, a failing CLI, output with no hash, empty
# output, JSON that does not parse, a hash that is not a string, no npx and no
# node, an unknown platform and a working directory that does not exist.
load test_helper

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export WORKFLOWS_TEST_CALLS="$CALLS"
  unset WORKFLOWS_OUT WORKFLOWS_PLATFORM GITHUB_ENV
}

fingerprint() { bash "$REPO_ROOT/scripts/native/expo/fingerprint.sh" "$@"; }

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

# Prints a directory holding only bash, the tools the script itself needs and
# the named ones, for a PATH on which a tool installed on this machine cannot
# satisfy the lookup a case is about.
bare_path() {
  local dir="$BATS_TEST_TMPDIR/bare" tool
  mkdir -p "$dir"
  for tool in bash dirname mkdir grep tr "$@"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

@test "the CLI runs in the consumer root from the consumer's own bin, and its JSON hash is read" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":"abc123","sources":[]}' \
    run fingerprint android
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "abc123" ] || fail "the hash was not read out of the JSON: $output"
  run cat "$CALLS"
  [ "$output" = "$(cd "$CONSUMER" && pwd -P)|--no fingerprint fingerprint:generate --platform android" ] \
    || fail "wrong directory or arguments: $output"
}

@test "the platform for the fingerprint may come from WORKFLOWS_PLATFORM" {
  stub_npx
  WORKFLOWS_PLATFORM=ios WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":"fromenv"}' run fingerprint
  [ "$output" = "fromenv" ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "--platform ios" || fail "the platform was not passed on: $output"
}

@test "a bare hash from an older CLI is read with its whitespace removed" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT=$'  bare111\n\n' run fingerprint ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "bare111" ] || fail "the bare hash was not read: $output"
}

@test "a failing fingerprint CLI is fatal and points at the missing devDependency" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_STATUS=1 run fingerprint ios
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::fingerprint:generate failed for ios" || fail "unexpected message: $output"
  contains "$output" "@expo/fingerprint a devDependency" || fail "does not say what is likely missing: $output"
}

@test "JSON output with no hash in it is fatal" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"sources":[]}' run fingerprint android
  [ "$status" -eq 1 ] || fail "an empty hash must not be returned: $output"
  contains "$output" "::error::could not read a fingerprint hash for android" || fail "unexpected message: $output"
}

@test "empty output from the CLI is fatal" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT=$' \n' run fingerprint ios
  [ "$status" -eq 1 ] || fail "an empty hash must not be returned: $output"
  contains "$output" "::error::could not read a fingerprint hash for ios" || fail "unexpected message: $output"
}

@test "no npx on PATH names the missing command" {
  PATH="$(bare_path)" run fingerprint ios
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: npx" || fail "does not name the missing command: $output"
}

@test "JSON output with no node on PATH names the missing command" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":"abc123"}' PATH="$(bare_path npx)" run fingerprint ios
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: node" || fail "does not name the missing command: $output"
}

@test "JSON output that does not parse is fatal, not a stack trace" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":' run fingerprint ios
  [ "$status" -eq 1 ] || fail "a hash out of broken JSON must not be returned: $output"
  contains "$output" "::error::could not read a fingerprint hash for ios" || fail "unexpected message: $output"
  not_contains "$output" "SyntaxError" || fail "node's stack trace leaked: $output"
}

@test "a hash that is not a string reads as no hash" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_OUTPUT='{"hash":42}' run fingerprint ios
  [ "$status" -eq 1 ] || fail "a non-string hash must not be returned: $output"
  contains "$output" "::error::could not read a fingerprint hash for ios" || fail "unexpected message: $output"
}

@test "an unknown platform stops before the CLI runs" {
  stub_npx
  run fingerprint windows
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "platform must be ios or android (got 'windows')" || fail "unexpected message: $output"
  [ ! -s "$CALLS" ] || fail "the CLI ran anyway: $(cat "$CALLS")"
}

@test "a working directory that does not exist stops before the CLI runs" {
  stub_npx
  WORKING_DIRECTORY=missing run fingerprint ios
  [ "$status" -eq 1 ] || fail "a fingerprint of the wrong directory must not be returned: $output"
  contains "$output" "the consumer's working directory does not exist" || fail "unexpected message: $output"
  [ ! -s "$CALLS" ] || fail "the CLI ran anyway: $(cat "$CALLS")"
}
