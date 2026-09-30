#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/android-maestro.sh: install and wire the app on the emulator,
# record, launch, run the Maestro suite (rerun once unless it hung), and
# always stop the recording and collect forensics. adb and maestro are fakes;
# the sibling scripts it calls (android-emulator.sh, app-launch.sh,
# collect-forensics.sh) are the real ones, running against the fakes.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export HOME="$BATS_TEST_TMPDIR/home"
  export WORKFLOWS_APP_ID=com.example.app WORKFLOWS_DEV_CLIENT=false
  mkdir -p "$GITHUB_WORKSPACE/.maestro" "$GITHUB_WORKSPACE/android/app/build/outputs/apk/debug" "$HOME" "$WORKFLOWS_OUT"
  printf 'apk\n' > "$GITHUB_WORKSPACE/android/app/build/outputs/apk/debug/app-debug.apk"
  : > "$WORKFLOWS_OUT/metro.log"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  # adb: records every call; a launch makes Metro serve a bundle; screenrecord
  # fails at once so the recording loop ends.
  cat > "$bin/adb" <<'STUB'
#!/usr/bin/env bash
printf 'adb %s\n' "$*" >> "$CALLS"
case "$*" in
  *"am start"*) echo "Bundled 1 modules" >> "$WORKFLOWS_OUT/metro.log" ;;
  *screenrecord*) exit 1 ;;
esac
exit 0
STUB
  cat > "$bin/maestro" <<'STUB'
#!/usr/bin/env bash
printf 'maestro %s\n' "$*" >> "$CALLS"
n=$(grep -c '^maestro ' "$CALLS")
set -- "$@" ""
out=""
while [ "$#" -gt 1 ]; do [ "$1" = --output ] && out="$2"; shift; done
[ -n "$out" ] && printf '<testsuites tests="%s"/>\n' "${MAESTRO_TESTS:-2}" > "$out"
read -r -a statuses <<< "${MAESTRO_STATUSES:-0}"
exit "${statuses[$((n - 1))]:-0}"
STUB
  chmod +x "$bin/adb" "$bin/maestro"
  export PATH="$bin:/usr/bin:/bin"
}

suite() { run bash "$REPO_ROOT/scripts/e2e/android-maestro.sh"; }
maestro_calls() { grep '^maestro ' "$CALLS"; }

@test "installs, wires the ports, launches, and runs the suite on Android with the app id and a junit report" {
  suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  calls="$(cat "$CALLS")"
  contains "$calls" "adb install -r $(cd "$GITHUB_WORKSPACE" && pwd -P)/android/app/build/outputs/apk/debug/app-debug.apk" || fail "calls: $calls"
  contains "$calls" "adb reverse tcp:8081 tcp:8081" || fail "calls: $calls"
  contains "$calls" "adb reverse tcp:8082 tcp:8082" || fail "calls: $calls"
  contains "$calls" "adb shell am start -n com.example.app/.MainActivity" || fail "calls: $calls"
  [ "$(maestro_calls)" = "maestro test .maestro --platform android -e APP_ID=com.example.app --debug-output $WORKFLOWS_OUT/maestro --flatten-debug-output --format junit --output $WORKFLOWS_OUT/maestro/junit.xml" ] \
    || fail "maestro: $(maestro_calls)"
  contains "$output" "Android: Maestro ran 2 flow(s)" || fail "output: $output"
}

@test "always stops the recording and collects forensics on the way out" {
  MAESTRO_STATUSES="1 1" suite
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  calls="$(cat "$CALLS")"
  contains "$calls" "adb shell pkill -INT screenrecord" || fail "recording not stopped: $calls"
  contains "$calls" "adb logcat -d" || fail "no forensics: $calls"
}

@test "passes the flows' config.yaml and the tag filters when there are any" {
  touch "$GITHUB_WORKSPACE/.maestro/config.yaml"
  WORKFLOWS_MAESTRO_INCLUDE_TAGS=smoke WORKFLOWS_MAESTRO_EXCLUDE_TAGS=slow suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(maestro_calls)" "--config .maestro/config.yaml" || fail "maestro: $(maestro_calls)"
  contains "$(maestro_calls)" "--include-tags smoke --exclude-tags slow" || fail "maestro: $(maestro_calls)"
}

@test "a failed suite is rerun once, and a hung one is not" {
  MAESTRO_STATUSES="1 0" suite
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(maestro_calls | wc -l | tr -d ' ')" -eq 2 ] || fail "maestro: $(maestro_calls)"
  : > "$CALLS"
  MAESTRO_STATUSES=124 suite
  [ "$status" -eq 124 ] || fail "expected 124, got $status: $output"
  [ "$(maestro_calls | wc -l | tr -d ' ')" -eq 1 ] || fail "reran a hung suite: $(maestro_calls)"
}

@test "a green suite that ran no flows fails" {
  MAESTRO_TESTS=0 suite
  [ "$status" -ne 0 ] || fail "passed with no flows: $output"
  contains "$output" "Maestro exited 0 but ran 0 flows" || fail "output: $output"
}

@test "without an APK the emulator is not prepared and nothing runs" {
  rm "$GITHUB_WORKSPACE/android/app/build/outputs/apk/debug/app-debug.apk"
  suite
  [ "$status" -ne 0 ] || fail "ran without an APK: $output"
  contains "$output" "android-emulator.sh prepare failed" || fail "output: $output"
  [ -z "$(maestro_calls)" ] || fail "maestro ran: $(maestro_calls)"
}

@test "a launch that fails stops before the suite" {
  rm "$WORKFLOWS_OUT/metro.log"
  suite
  [ "$status" -ne 0 ] || fail "ran after a failed launch: $output"
  contains "$output" "app-launch.sh android failed" || fail "output: $output"
  [ -z "$(maestro_calls)" ] || fail "maestro ran: $(maestro_calls)"
}

@test "a failing setup hook stops before the launch" {
  printf 'exit 1\n' > "$GITHUB_WORKSPACE/up.sh"
  WORKFLOWS_E2E_SETUP_SCRIPT=up.sh suite
  [ "$status" -ne 0 ] || fail "ran after a failed setup: $output"
  contains "$output" "WORKFLOWS_E2E_SETUP_SCRIPT failed" || fail "output: $output"
  not_contains "$(cat "$CALLS")" "am start" || fail "launched anyway: $(cat "$CALLS")"
}

@test "no flows directory fails, naming it" {
  rmdir "$GITHUB_WORKSPACE/.maestro"
  suite
  [ "$status" -ne 0 ] || fail "ran without flows: $output"
  contains "$output" "no flows directory at" || fail "output: $output"
}

@test "a driver startup timeout at or over the suite bound fails before anything runs" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=600000 suite
  [ "$status" -ne 0 ] || fail "accepted a timeout over the bound: $output"
  [ ! -s "$CALLS" ] || fail "ran anyway: $(cat "$CALLS")"
}

@test "no adb is named" {
  rm "$bin/adb"
  suite
  [ "$status" -ne 0 ] || fail "ran without adb: $output"
  contains "$output" "missing command: adb" || fail "output: $output"
}

@test "the caller's arguments go to maestro test last, after every flag the script sets" {
  run bash "$REPO_ROOT/scripts/e2e/android-maestro.sh" --include-tags smoke --exclude-tags slow
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(maestro_calls)" = "maestro test .maestro --platform android -e APP_ID=com.example.app --debug-output $WORKFLOWS_OUT/maestro --flatten-debug-output --format junit --output $WORKFLOWS_OUT/maestro/junit.xml --include-tags smoke --exclude-tags slow" ] \
    || fail "maestro: $(maestro_calls)"
}
