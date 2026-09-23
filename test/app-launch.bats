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
  PATH="$bin:$PATH"
  export PATH
}

launch() { run bash "$REPO_ROOT/scripts/e2e/app-launch.sh" "$@"; }

# The bug this file was written for: check-e2e.yml stopped starting Metro for a
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
