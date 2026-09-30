#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/android-build.sh: the consumer's Gradle wrapper builds the
# debug APK for the emulator's ABI, and the APK's path is the apk output.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_OUTPUT"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  mkdir -p "$GITHUB_WORKSPACE/android"
  cat > "$GITHUB_WORKSPACE/android/gradlew" <<'STUB'
#!/usr/bin/env bash
printf 'gradlew %s | cwd=%s\n' "$*" "$PWD" >> "$CALLS"
[ "${GRADLE_STATUS:-0}" -eq 0 ] || exit "$GRADLE_STATUS"
[ -n "${GRADLE_NO_APK:-}" ] && exit 0
mkdir -p app/build/outputs/apk/debug
printf 'apk\n' > app/build/outputs/apk/debug/app-debug.apk
STUB
  chmod +x "$GITHUB_WORKSPACE/android/gradlew"
  root="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
}

@test "builds the debug APK for x86_64 by default and publishes its path" {
  run bash "$REPO_ROOT/scripts/native/android-build.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$CALLS")" = "gradlew :app:assembleDebug -PreactNativeArchitectures=x86_64 --no-daemon --build-cache | cwd=$root/android" ] \
    || fail "calls: $(cat "$CALLS")"
  contains "$(cat "$GITHUB_OUTPUT")" "apk=$root/android/app/build/outputs/apk/debug/app-debug.apk" \
    || fail "output: $(cat "$GITHUB_OUTPUT")"
}

@test "WORKFLOWS_ANDROID_ABIS picks the architectures" {
  WORKFLOWS_ANDROID_ABIS=arm64-v8a run bash "$REPO_ROOT/scripts/native/android-build.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$CALLS")" "-PreactNativeArchitectures=arm64-v8a" || fail "calls: $(cat "$CALLS")"
}

@test "without an executable Gradle wrapper it names the step that makes one" {
  chmod -x "$GITHUB_WORKSPACE/android/gradlew"
  run bash "$REPO_ROOT/scripts/native/android-build.sh"
  [ "$status" -ne 0 ] || fail "ran without a wrapper: $output"
  contains "$output" "run prebuild.sh android first" || fail "output: $output"
}

@test "a failing build fails the script" {
  GRADLE_STATUS=4 run bash "$REPO_ROOT/scripts/native/android-build.sh"
  [ "$status" -eq 4 ] || fail "expected 4, got $status: $output"
}

@test "a build that succeeds without an APK is a failure that names the path" {
  GRADLE_NO_APK=1 run bash "$REPO_ROOT/scripts/native/android-build.sh"
  [ "$status" -ne 0 ] || fail "passed with no APK: $output"
  contains "$output" "assembleDebug succeeded but $root/android/app/build/outputs/apk/debug/app-debug.apk is missing" \
    || fail "output: $output"
}
