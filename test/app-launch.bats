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
