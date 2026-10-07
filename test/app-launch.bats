#!/usr/bin/env bats
# app-launch.sh is the most-rewritten script in the iOS E2E path, and until now
# nothing covered it. Every regression it has had was the same shape: a
# precondition that held only because some other step happened to run first.
# The Release path is exactly that - it shares a script with a launch that does
# need Metro - so both branches are pinned here.
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$WORKFLOWS_OUT"
  export WORKFLOWS_SIM_UDID=SIM-UDID
  export WORKFLOWS_APP_ID=com.example.app
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  for tool in xcrun adb maestro; do
    cat > "$bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$CALLS"
STUB
    chmod +x "$bin/$tool"
  done
  # The launcher component adb resolves for the package: ADB_LAUNCHER when set,
  # else <package>/.MainActivity, the shape a package whose namespace is its
  # applicationId resolves to.
  cat >> "$bin/adb" <<'STUB'
case "$*" in
  *"resolve-activity"*)
    if [ -n "${ADB_LAUNCHER+x}" ]; then printf '%s\r\n' "$ADB_LAUNCHER"; else printf 'priority=0 preferredOrder=0\r\n%s/.MainActivity\r\n' "${!#}"; fi ;;
esac
STUB
  # Metro's /status, as the fake curl answers it: METRO_STATUS when set, else a
  # refused connection - so no Metro on this machine's real port can leak in.
  cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$CALLS"
[ -n "${METRO_STATUS:-}" ] || exit 7
printf '%s' "$METRO_STATUS"
STUB
  chmod +x "$bin/curl"
  PATH="$bin:$PATH"
  export PATH
  # The Expo stack unless a case says otherwise: these cases were written for
  # it, and a run from this checkout would otherwise detect the bare stack.
  export WORKFLOWS_NATIVE_STACK_INPUT=expo
}

launch() { run bash "$REPO_ROOT/scripts/e2e/app-launch.sh" "$@"; }

# The bug this file was written for: test-e2e.yml stopped starting Metro for a
# Release build (it embeds its bundle and never asks for one), and the launch
# died on a metro.log that nothing had any reason to create.
@test "a Release iOS launch needs no metro.log" {
  WORKFLOWS_IOS_CONFIGURATION=Release WORKFLOWS_DEV_CLIENT=false launch ios
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "Metro is not asked" || fail "output: $output"
  grep -q 'xcrun simctl launch SIM-UDID com.example.app' "$CALLS" ||
    fail "did not launch the app: $(cat "$CALLS")"
}

# ...and it must not silently swallow the other direction: a Debug launch reads
# metro.log to confirm the app really asked for a bundle, so a missing one is a
# broken job, not a thing to shrug at.
@test "a Debug iOS launch still demands metro.log" {
  WORKFLOWS_IOS_CONFIGURATION=Debug WORKFLOWS_DEV_CLIENT=true launch ios
  [ "$status" -ne 0 ] || fail "a missing metro.log passed; output: $output"
  contains "$output" "run metro-start.sh first" || fail "output: $output"
  contains "$output" "no Metro answering on port 8081" || fail "output: $output"
}

@test "an Android launch still demands metro.log whatever the iOS configuration says" {
  WORKFLOWS_IOS_CONFIGURATION=Release WORKFLOWS_DEV_CLIENT=false launch android
  [ "$status" -ne 0 ] || fail "a missing metro.log passed; output: $output"
  contains "$output" "run metro-start.sh first" || fail "output: $output"
}

@test "a Debug iOS launch reports the bundle Metro served" {
  printf 'metro started\n' > "$WORKFLOWS_OUT/metro.log"
  ( sleep 1; printf 'iOS Bundled 500ms index.js\n' >> "$WORKFLOWS_OUT/metro.log" ) &
  WORKFLOWS_IOS_CONFIGURATION=Debug WORKFLOWS_DEV_CLIENT=false launch ios
  wait
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "app is up" || fail "output: $output"
  traced "$output" "Wait for the app to request its bundle" || fail "the wait was not timed: $output"
}

# Metro a developer started in their own terminal writes no metro.log, but it is
# the Metro the deep link points at: the launch goes ahead without a receipt.
@test "a Debug iOS launch against a Metro started elsewhere opens the deep link on its port" {
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json"
  printf '{"scheme":"exampleapp"}\n' > "$EXPO_CONFIG_JSON"
  METRO_STATUS=packager-status:running WORKFLOWS_METRO_PORT=8091 \
    WORKFLOWS_IOS_CONFIGURATION=Debug WORKFLOWS_DEV_CLIENT=true launch ios
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "Metro on port 8091 was started outside metro-start.sh" || fail "output: $output"
  contains "$output" "com.example.app launched against the Metro already running on port 8091" || fail "output: $output"
  grep -q 'curl -s --max-time 5 http://localhost:8091/status' "$CALLS" || fail "did not ask Metro: $(cat "$CALLS")"
  grep -q 'xcrun simctl openurl SIM-UDID exampleapp://expo-development-client/?url=http%3A%2F%2Flocalhost%3A8091' "$CALLS" ||
    fail "did not open the deep link: $(cat "$CALLS")"
}

@test "an Android launch against a Metro started elsewhere opens the deep link through the host loopback" {
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json"
  printf '{"scheme":"exampleapp"}\n' > "$EXPO_CONFIG_JSON"
  METRO_STATUS=packager-status:running WORKFLOWS_DEV_CLIENT=true launch android
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "launched against the Metro already running on port 8081" || fail "output: $output"
  grep -q 'adb shell am start -a android.intent.action.VIEW -d exampleapp://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A8081' "$CALLS" ||
    fail "did not open the deep link: $(cat "$CALLS")"
}

@test "something else answering on the Metro port is not Metro" {
  METRO_STATUS='<html>not metro</html>' WORKFLOWS_IOS_CONFIGURATION=Debug WORKFLOWS_DEV_CLIENT=false launch ios
  [ "$status" -ne 0 ] || fail "launched against a server that is not Metro; output: $output"
  contains "$output" "no Metro answering on port 8081" || fail "output: $output"
  not_contains "$(cat "$CALLS")" "xcrun" || fail "launched anyway: $(cat "$CALLS")"
}

@test "with no curl to ask, a missing metro.log still fails" {
  rm "$bin/curl"
  mkdir -p "$BATS_TEST_TMPDIR/nocurl"
  for tool in bash dirname cat mkdir grep wc seq tail sleep mktemp rm pwd sed; do
    real="$(command -v "$tool")" && ln -s "$real" "$BATS_TEST_TMPDIR/nocurl/$tool"
  done
  PATH="$bin:$BATS_TEST_TMPDIR/nocurl" WORKFLOWS_IOS_CONFIGURATION=Debug WORKFLOWS_DEV_CLIENT=false \
    run "$BATS_TEST_TMPDIR/nocurl/bash" "$REPO_ROOT/scripts/e2e/app-launch.sh" ios
  [ "$status" -ne 0 ] || fail "a missing metro.log passed without curl; output: $output"
  contains "$output" "no Metro answering on port 8081" || fail "output: $output"
}

# --- the bare native stack ---------------------------------------------------
#
# A bare React Native app has no dev-client launcher and no expo: it is
# launched plainly, its identifiers come from the committed native projects,
# and the React Native CLI's Metro logs its receipt as "BUNDLE".

@test "a bare app is launched plainly on iOS, and the CLI Metro's BUNDLE line is the receipt" {
  printf 'metro started\n' > "$WORKFLOWS_OUT/metro.log"
  ( sleep 1; printf ' BUNDLE  ./index.js\n' >> "$WORKFLOWS_OUT/metro.log" ) &
  WORKFLOWS_NATIVE_STACK_INPUT=bare WORKFLOWS_IOS_CONFIGURATION=Debug WORKFLOWS_DEV_CLIENT=false launch ios
  wait
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "app is up" || fail "output: $output"
  grep -q 'xcrun simctl launch SIM-UDID com.example.app' "$CALLS" || fail "not a plain launch: $(cat "$CALLS")"
  not_contains "$(cat "$CALLS")" "openurl" || fail "a deep link was opened: $(cat "$CALLS")"
}

@test "the bare fixture's Android app is launched by its applicationId, with no expo anywhere" {
  unset WORKFLOWS_APP_ID WORKFLOWS_NATIVE_STACK_INPUT
  printf 'metro started\n' > "$WORKFLOWS_OUT/metro.log"
  ( sleep 1; printf ' BUNDLE  ./index.js\n' >> "$WORKFLOWS_OUT/metro.log" ) &
  GITHUB_WORKSPACE="$FIXTURES/consumer-bare" WORKING_DIRECTORY=. WORKFLOWS_DEV_CLIENT=false launch android
  wait
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "launching com.example.bare on android (dev-client=false)" || fail "output: $output"
  grep -q 'adb shell am start -n com.example.bare/.MainActivity' "$CALLS" || fail "not a plain launch: $(cat "$CALLS")"
}

# The bug: the launch guessed <applicationId>/.MainActivity, which does not
# exist when the activity lives in another namespace (blink-terminal-app's
# sv.blink.terminal runs com.blinkterminalapp.MainActivity).
@test "a bare Android launch starts the activity the package declares, whatever its namespace" {
  printf 'metro started\n' > "$WORKFLOWS_OUT/metro.log"
  ( sleep 1; printf ' BUNDLE  ./index.js\n' >> "$WORKFLOWS_OUT/metro.log" ) &
  ADB_LAUNCHER=com.example.app/com.other.namespace.MainActivity WORKFLOWS_NATIVE_STACK_INPUT=bare \
    GITHUB_WORKSPACE="$FIXTURES/consumer-bare" WORKING_DIRECTORY=. WORKFLOWS_DEV_CLIENT=false launch android
  wait
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  grep -q 'adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.example.app' "$CALLS" ||
    fail "did not ask for the launcher activity: $(cat "$CALLS")"
  grep -q 'adb shell am start -n com.example.app/com.other.namespace.MainActivity' "$CALLS" ||
    fail "did not start the declared activity: $(cat "$CALLS")"
}

@test "a package with no launcher activity on the device fails with the fix, before any start" {
  METRO_STATUS=packager-status:running ADB_LAUNCHER="No activity found" WORKFLOWS_NATIVE_STACK_INPUT=bare \
    GITHUB_WORKSPACE="$FIXTURES/consumer-bare" WORKING_DIRECTORY=. WORKFLOWS_DEV_CLIENT=false launch android
  [ "$status" -ne 0 ] || fail "launched nothing and passed; output: $output"
  contains "$output" "com.example.app has no launcher activity on the device" || fail "output: $output"
  contains "$output" "Is the debug build installed?" || fail "no fix: $output"
  not_contains "$(cat "$CALLS")" "am start" || fail "started anyway: $(cat "$CALLS")"
}

@test "dev-client on for an app with no URL scheme fails with the fix, before any launch" {
  METRO_STATUS=packager-status:running WORKFLOWS_NATIVE_STACK_INPUT=bare \
    GITHUB_WORKSPACE="$FIXTURES/consumer-bare" WORKING_DIRECTORY=. WORKFLOWS_DEV_CLIENT=true launch android
  [ "$status" -ne 0 ] || fail "launched with no scheme; output: $output"
  contains "$output" "dev-client is on, but the app declares no URL scheme" || fail "output: $output"
  contains "$output" "pass dev-client: false" || fail "no fix: $output"
  not_contains "$(cat "$CALLS")" "adb" || fail "launched anyway: $(cat "$CALLS")"
}

@test "dev-client on for a bare app that declares a scheme opens the deep link with it" {
  app="$BATS_TEST_TMPDIR/app"
  mkdir -p "$app/android/app/src/main"
  printf '<manifest><data android:scheme="bareapp"/></manifest>\n' > "$app/android/app/src/main/AndroidManifest.xml"
  METRO_STATUS=packager-status:running WORKFLOWS_NATIVE_STACK_INPUT=bare \
    GITHUB_WORKSPACE="$app" WORKING_DIRECTORY=. WORKFLOWS_DEV_CLIENT=true launch ios
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  grep -q 'xcrun simctl openurl SIM-UDID bareapp://expo-development-client/' "$CALLS" || fail "$(cat "$CALLS")"
}
