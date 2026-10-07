#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/prebuild.sh: the thin dispatcher the workflows call. It hands
# the platform to the consumer's native stack (scripts/lib/native-stack.sh):
# the Expo stack runs `expo prebuild` (pnpm is a fake that records the call),
# the bare stack checks the committed tree and generates nothing. Run against
# both fixture consumers, and with the stack named by the input. The stacks'
# own behaviour is in native-expo-prebuild.bats and native-bare-prebuild.bats.
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'pnpm %s\n' "$*" >> "$CALLS"
STUB
  as_fakes "$bin/pnpm"
  export PATH="$bin:$PATH"
  export WORKING_DIRECTORY=.
  unset WORKFLOWS_NATIVE_STACK_INPUT
}

prebuild() { run bash "$REPO_ROOT/scripts/native/prebuild.sh" "$@"; }

@test "the Expo fixture is prebuilt with expo prebuild" {
  GITHUB_WORKSPACE="$FIXTURES/consumer-min" prebuild android
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "native stack: expo (" || fail "the stack was not detected: $output"
  contains "$(cat "$CALLS")" "pnpm exec expo prebuild --platform android --clean --no-install" || fail "$(cat "$CALLS")"
}

@test "the bare fixture's committed tree is checked, and nothing is generated" {
  for platform in ios android; do
    GITHUB_WORKSPACE="$FIXTURES/consumer-bare" prebuild "$platform"
    [ "$status" -eq 0 ] || fail "$platform: exited $status: $output"
    contains "$output" "native stack: bare (" || fail "$platform: the stack was not detected: $output"
    contains "$output" "bare native stack: $platform/ is committed" || fail "$platform: $output"
  done
  [ ! -s "$CALLS" ] || fail "the bare stack ran a generator: $(cat "$CALLS")"
}

@test "the native-stack input overrides detection" {
  WORKFLOWS_NATIVE_STACK_INPUT=expo GITHUB_WORKSPACE="$FIXTURES/consumer-bare" prebuild ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$CALLS")" "pnpm exec expo prebuild --platform ios" || fail "the input did not decide: $(cat "$CALLS")"
}

@test "the platform reaches the stack's script, and its refusal is the script's" {
  GITHUB_WORKSPACE="$FIXTURES/consumer-min" prebuild web
  [ "$status" -ne 0 ] || fail "accepted web: $output"
  contains "$output" "platform must be ios or android (got 'web')" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "ran anyway: $(cat "$CALLS")"
}

@test "an invalid native-stack input stops before any prebuild" {
  WORKFLOWS_NATIVE_STACK_INPUT=cordova GITHUB_WORKSPACE="$FIXTURES/consumer-min" prebuild ios
  [ "$status" -ne 0 ] || fail "accepted cordova: $output"
  contains "$output" "expected expo, bare or empty" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "ran anyway: $(cat "$CALLS")"
}
