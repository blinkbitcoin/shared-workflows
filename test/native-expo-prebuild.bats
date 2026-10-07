#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/expo/prebuild.sh, the Expo stack's prebuild: `expo prebuild`
# for one platform, clean and without installing pods, in the consumer's
# working directory. pnpm is a fake that records how it was called.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$GITHUB_WORKSPACE"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'pnpm %s | cwd=%s CI=%s EXPO_NO_GIT_STATUS=%s\n' "$*" "$PWD" "${CI:-}" "${EXPO_NO_GIT_STATUS:-}" >> "$CALLS"
exit "${PNPM_STATUS:-0}"
STUB
  as_fakes "$bin/pnpm"
  export PATH="$bin:$PATH"
}

@test "prebuilds the platform given as an argument, clean and without installing, in the consumer root" {
  for platform in ios android; do
    : > "$CALLS"
    run bash "$REPO_ROOT/scripts/native/expo/prebuild.sh" "$platform"
    [ "$status" -eq 0 ] || fail "$platform: exited $status: $output"
    contains "$(cat "$CALLS")" "pnpm exec expo prebuild --platform $platform --clean --no-install | cwd=$(cd "$GITHUB_WORKSPACE" && pwd -P) CI=1 EXPO_NO_GIT_STATUS=1" \
      || fail "$platform: $(cat "$CALLS")"
  done
}

@test "takes the platform from WORKFLOWS_PLATFORM when no argument is given" {
  WORKFLOWS_PLATFORM=android run bash "$REPO_ROOT/scripts/native/expo/prebuild.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$CALLS")" "--platform android" || fail "$(cat "$CALLS")"
}

@test "an unknown platform fails before anything runs" {
  run bash "$REPO_ROOT/scripts/native/expo/prebuild.sh" web
  [ "$status" -ne 0 ] || fail "accepted web: $output"
  contains "$output" "platform must be ios or android (got 'web')" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "ran anyway: $(cat "$CALLS")"
}

@test "a failing prebuild fails the script" {
  PNPM_STATUS=3 run bash "$REPO_ROOT/scripts/native/expo/prebuild.sh" ios
  [ "$status" -eq 3 ] || fail "expected 3, got $status: $output"
}

@test "no pnpm on PATH is named" {
  rm "$bin/pnpm"
  PATH="$bin:/usr/bin:/bin" run bash "$REPO_ROOT/scripts/native/expo/prebuild.sh" ios
  [ "$status" -ne 0 ] || fail "ran without pnpm: $output"
  contains "$output" "missing command: pnpm" || fail "output: $output"
}
