#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/ios-simulator.sh: every subcommand the iOS end-to-end job runs
# against the simulator - pick, wait, install, record start|stop, shutdown - and
# the usage refusals for anything else. Covered: which simulator pick prefers
# and where it records the choice, install from a bundle and from a tar and its
# URL-scheme pre-approval, the recording and the unified log that runs beside
# it, and each refusal (no xcrun, no plutil, no simulator, no bundle).
# What the unified-log predicate matches is ios-unified-log.bats' question: it
# is a function of scripts/lib/e2e-env.sh.
#
# xcrun and plutil are stubbed. xcrun records its arguments, answers the device
# list from STUB_DEVICES and, for the two long-running commands, sleeps so the
# script has a real pid to signal. plutil answers from STUB_BUNDLE_ID and
# STUB_URL_TYPES and fails like plutil does on a missing key.
load test_helper

SCRIPT="$REPO_ROOT/scripts/e2e/ios-simulator.sh"

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/ghenv"
  : > "$GITHUB_ENV"
  mkdir -p "$WORKFLOWS_OUT"
  export WORKFLOWS_SIM_UDID=SIM-UDID
  export WORKFLOWS_APP_ID=com.example.app
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json"
  printf '{"name":"App","scheme":"myapp","ios":{"bundleIdentifier":"com.example.app"}}\n' > "$EXPO_CONFIG_JSON"
  app="$BATS_TEST_TMPDIR/App.app"
  mkdir -p "$app"
  : > "$app/Info.plist"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  cat > "$bin/xcrun" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$*" in
  *recordVideo*|*"log stream"*) exec sleep 30 ;;
  "simctl list -j devices available") none='{"devices":{}}'; printf '%s\n' "\${STUB_DEVICES:-\$none}" ;;
  "simctl list devices available") printf 'the plain device list\n' ;;
  "simctl boot "*|"simctl bootstatus "*|"simctl shutdown "*) exit "\${STUB_SIMCTL_STATUS:-0}" ;;
esac
STUB
  # plutil stub: answers the two extracts the script makes from the test's
  # STUB_BUNDLE_ID / STUB_URL_TYPES, and fails like plutil does on a missing key.
  cat > "$bin/plutil" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  CFBundleIdentifier) [ -n "${STUB_BUNDLE_ID:-}" ] || exit 1; printf '%s\n' "$STUB_BUNDLE_ID" ;;
  CFBundleURLTypes) [ -n "${STUB_URL_TYPES:-}" ] || exit 1; printf '%s\n' "$STUB_URL_TYPES" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$bin/xcrun" "$bin/plutil"
  PATH="$bin:$PATH"
  export PATH
  export STUB_BUNDLE_ID=com.example.app
}

sim() { bash "$REPO_ROOT/scripts/e2e/ios-simulator.sh" "$@"; }

install_app() { run bash "$REPO_ROOT/scripts/e2e/ios-simulator.sh" install "${1:-$app}"; }

approval() { # <scheme>
  printf 'simctl spawn SIM-UDID defaults write com.apple.launchservices.schemeapproval com.apple.CoreSimulator.CoreSimulatorBridge-->%s -string com.example.app' "$1"
}

# A device list in simctl's shape, one runtime, from "udid:name:state" triples.
devices() {
  local entry udid name state rows=""
  for entry in "$@"; do
    IFS=: read -r udid name state <<< "$entry"
    rows="$rows${rows:+,}{\"udid\":\"$udid\",\"name\":\"$name\",\"state\":\"$state\",\"isAvailable\":true}"
  done
  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[%s]}}' "$rows"
}

# A PATH holding only the named tools, linked from the real PATH, plus any
# stubs from this file's bin directory named with a "stub:" prefix. A stub
# needs bash on the PATH too: it starts with `#!/usr/bin/env bash`.
only_path() {
  local only="$BATS_TEST_TMPDIR/only" tool
  mkdir -p "$only"
  for tool in "$@"; do
    case "$tool" in
      stub:*) ln -sf "$bin/${tool#stub:}" "$only/${tool#stub:}" ;;
      *) ln -sf "$(command -v "$tool")" "$only/$tool" ;;
    esac
  done
  printf '%s\n' "$only"
}

# --- pick --------------------------------------------------------------------

@test "pick prefers a booted iPhone, and records it everywhere the later steps read it" {
  export STUB_DEVICES
  STUB_DEVICES="$(devices "NEW-1:iPhone 16:Shutdown" "OLD-1:iPhone 11:Booted" "PAD-1:iPad Pro:Booted")"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  : > "$GITHUB_OUTPUT"
  export GITHUB_OUTPUT
  run sim pick
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "Using simulator: iPhone 11 (OLD-1)" || fail "did not prefer the booted iPhone: $output"
  [ "$(cat "$WORKFLOWS_OUT/sim-udid")" = "OLD-1" ] || fail "sim-udid holds: $(cat "$WORKFLOWS_OUT/sim-udid")"
  grep -qx "udid=OLD-1" "$GITHUB_OUTPUT" || fail "no udid step output: $(cat "$GITHUB_OUTPUT")"
  grep -qx "WORKFLOWS_SIM_UDID=OLD-1" "$GITHUB_ENV" || fail "no WORKFLOWS_SIM_UDID for later steps: $(cat "$GITHUB_ENV")"
  grep -qx "simctl boot OLD-1" "$CALLS" || fail "the chosen simulator was not booted: $(cat "$CALLS")"
}

@test "with none booted, pick prefers an iPhone 15 or later over an older one" {
  export STUB_DEVICES
  STUB_DEVICES="$(devices "OLD-1:iPhone 11:Shutdown" "PAD-1:iPad Pro:Booted" "NEW-1:iPhone 16 Pro:Shutdown")"
  run sim pick
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "Using simulator: iPhone 16 Pro (NEW-1)" || fail "did not prefer the recent iPhone: $output"
  grep -qx "simctl boot NEW-1" "$CALLS" || fail "calls: $(cat "$CALLS")"
}

@test "with only older iPhones, pick takes the first of them" {
  export STUB_DEVICES
  STUB_DEVICES="$(devices "PAD-1:iPad Pro:Shutdown" "OLD-1:iPhone 11:Shutdown" "OLD-2:iPhone 12:Shutdown")"
  run sim pick
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "Using simulator: iPhone 11 (OLD-1)" || fail "did not fall back to an older iPhone: $output"
}

@test "pick without GITHUB_OUTPUT prints the udid output on standard output" {
  export STUB_DEVICES
  STUB_DEVICES="$(devices "NEW-1:iPhone 16:Shutdown")"
  run sim pick
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "udid=NEW-1" || fail "no udid line outside a runner: $output"
}

@test "a simulator that is already booted does not fail pick" {
  # simctl boot fails on a booted device; that is the state pick wants.
  export STUB_DEVICES STUB_SIMCTL_STATUS=149
  STUB_DEVICES="$(devices "NEW-1:iPhone 16:Booted")"
  run sim pick
  [ "$status" -eq 0 ] || fail "a failed boot failed pick: status $status; output: $output"
  grep -qx "simctl boot NEW-1" "$CALLS" || fail "calls: $(cat "$CALLS")"
}

@test "a machine with no iPhone simulator is refused, and the device list is shown" {
  export STUB_DEVICES
  STUB_DEVICES="$(devices "PAD-1:iPad Pro:Booted")"
  run sim pick
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::no available iPhone simulator on this machine" || fail "output: $output"
  contains "$output" "the plain device list" || fail "the device list was not shown: $output"
  [ ! -f "$WORKFLOWS_OUT/sim-udid" ] || fail "a udid was recorded: $(cat "$WORKFLOWS_OUT/sim-udid")"
  ! grep -q "simctl boot" "$CALLS" || fail "something was booted: $(cat "$CALLS")"
}

@test "a runner without xcrun is refused before any subcommand runs" {
  local only
  only="$(only_path dirname mkdir jq)"
  run env PATH="$only" "$BASH" "$SCRIPT" pick
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: xcrun" || fail "output: $output"
}

# --- wait ----------------------------------------------------------------

@test "wait blocks on the picked simulator's boot, read from the recorded udid" {
  unset WORKFLOWS_SIM_UDID
  printf 'PICKED-1\n' > "$WORKFLOWS_OUT/sim-udid"
  run sim wait
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  grep -qx "simctl bootstatus PICKED-1 -b" "$CALLS" || fail "calls: $(cat "$CALLS")"
}

@test "wait fails when the simulator never finishes booting" {
  STUB_SIMCTL_STATUS=3 run sim wait
  [ "$status" -eq 3 ] || fail "expected bootstatus's exit 3, got $status: $output"
}

@test "wait before pick names the missing step" {
  unset WORKFLOWS_SIM_UDID
  run sim wait
  contains "$output" "::error::no simulator selected - run ios-simulator.sh pick first" || fail "output: $output"
}

# --- install -------------------------------------------------------------
#
# install pre-approves every URL scheme the app declares, so `simctl openurl`
# never raises iOS's "Open in <app>?" alert. That alert is what killed the
# XCTest driver mid-suite (run 36049645029 in react-native-mobile-template) and
# queued unanswerable alerts for the retry; these cases pin that each declared
# scheme gets its approval, and that an app with none is not an error.

@test "install pre-approves every scheme across every URL type" {
  export STUB_URL_TYPES='[{"CFBundleURLSchemes":["myapp","com.example.app"]},{"CFBundleURLSchemes":["exp+my-app"]}]'
  install_app
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  grep -qx "simctl install SIM-UDID $app" "$CALLS" || fail "app not installed: $(cat "$CALLS")"
  for scheme in myapp com.example.app exp+my-app; do
    grep -qxF "$(approval "$scheme")" "$CALLS" || fail "no approval for $scheme: $(cat "$CALLS")"
  done
  [ "$(grep -c schemeapproval "$CALLS")" -eq 3 ] || fail "expected 3 approvals: $(cat "$CALLS")"
  contains "$output" "pre-approved URL schemes for com.example.app: myapp com.example.app exp+my-app" ||
    fail "output: $output"
}

# Approving before installing would be approving for an app LaunchServices has
# never seen; the order is part of the fix.
@test "the approvals are written after the install" {
  export STUB_URL_TYPES='[{"CFBundleURLSchemes":["myapp"]}]'
  install_app
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ "$(sed -n 1p "$CALLS")" = "simctl install SIM-UDID $app" ] || fail "calls: $(cat "$CALLS")"
  [ "$(sed -n 2p "$CALLS")" = "$(approval myapp)" ] || fail "calls: $(cat "$CALLS")"
}

@test "an app with no URL types installs and writes no approval" {
  unset STUB_URL_TYPES
  install_app
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  ! grep -q schemeapproval "$CALLS" || fail "wrote an approval: $(cat "$CALLS")"
  contains "$output" "declares no URL schemes" || fail "output: $output"
}

@test "a URL type without schemes is skipped, not an error" {
  export STUB_URL_TYPES='[{"CFBundleURLName":"no-schemes"},{"CFBundleURLSchemes":["myapp"]}]'
  install_app
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ "$(grep -c schemeapproval "$CALLS")" -eq 1 ] || fail "expected 1 approval: $(cat "$CALLS")"
  grep -qxF "$(approval myapp)" "$CALLS" || fail "calls: $(cat "$CALLS")"
}

@test "an Info.plist without a bundle id fails the install step" {
  unset STUB_BUNDLE_ID
  export STUB_URL_TYPES='[{"CFBundleURLSchemes":["myapp"]}]'
  install_app
  [ "$status" -ne 0 ] || fail "a missing bundle id passed; output: $output"
  contains "$output" "no CFBundleIdentifier" || fail "output: $output"
  ! grep -q schemeapproval "$CALLS" || fail "wrote an approval: $(cat "$CALLS")"
}

# The CI path: build-ios.yml ships the app as a tar, and the approval has to
# read the Info.plist of the extracted copy, not the tar.
@test "an app installed from a tar is pre-approved from the extracted bundle" {
  export STUB_URL_TYPES='[{"CFBundleURLSchemes":["myapp"]}]'
  tar -C "$BATS_TEST_TMPDIR" -cf "$BATS_TEST_TMPDIR/app.tar" App.app
  install_app "$BATS_TEST_TMPDIR/app.tar"
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  grep -qx "simctl install SIM-UDID $WORKFLOWS_OUT/app/App.app" "$CALLS" || fail "calls: $(cat "$CALLS")"
  grep -qxF "$(approval myapp)" "$CALLS" || fail "calls: $(cat "$CALLS")"
}

@test "installing from a tar replaces what an earlier install extracted" {
  mkdir -p "$WORKFLOWS_OUT/app/Old.app"
  tar -C "$BATS_TEST_TMPDIR" -cf "$BATS_TEST_TMPDIR/app.tar" App.app
  install_app "$BATS_TEST_TMPDIR/app.tar"
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ ! -e "$WORKFLOWS_OUT/app/Old.app" ] || fail "the earlier extraction survived"
  contains "$output" "installed $WORKFLOWS_OUT/app/App.app" || fail "output: $output"
}

@test "install without a path is a usage error" {
  run sim install
  [ "$status" -ne 0 ] || fail "install with no path passed: $output"
  contains "$output" "usage: ios-simulator.sh install <app.tar|App.app>" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "xcrun was called: $(cat "$CALLS")"
}

@test "install of a path that does not exist is refused, naming it" {
  run sim install "$BATS_TEST_TMPDIR/missing.tar"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::no such app bundle or tar: $BATS_TEST_TMPDIR/missing.tar" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "xcrun was called: $(cat "$CALLS")"
}

@test "a tar with no .app at its top is refused, naming the tar" {
  mkdir -p "$BATS_TEST_TMPDIR/pack/Payload"
  : > "$BATS_TEST_TMPDIR/pack/Payload/readme"
  tar -C "$BATS_TEST_TMPDIR/pack" -cf "$BATS_TEST_TMPDIR/empty.tar" Payload
  run sim install "$BATS_TEST_TMPDIR/empty.tar"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::no .app inside $BATS_TEST_TMPDIR/empty.tar" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "xcrun was called: $(cat "$CALLS")"
}

@test "an install on a runner without plutil is refused after the install, before any approval" {
  local only
  only="$(only_path dirname mkdir jq bash stub:xcrun)"
  run env PATH="$only" "$BASH" "$SCRIPT" install "$app"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: plutil" || fail "output: $output"
  ! grep -q schemeapproval "$CALLS" || fail "wrote an approval: $(cat "$CALLS")"
}

# --- record --------------------------------------------------------------
#
# `record start|stop` also streams the simulator's unified log next to the
# video. It exists because a deep link that reached the app ~40s late could
# only be *inferred* from Maestro screenshots; SpringBoard's alert lifecycle and
# FrontBoard's UIOpenURLAction hand-off are what actually explain it, and they
# live in this log.

@test "record start streams the unified log beside the video, with its own pid file" {
  run sim record start
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  # Both xcrun calls are backgrounded, so the stub may not have logged its
  # arguments by the time the script returns: give it a moment.
  for _ in $(seq 1 50); do [ "$(grep -c . "$CALLS")" -ge 2 ] && break; sleep 0.1; done
  grep -q "recordVideo" "$CALLS" || fail "no recordVideo call: $(cat "$CALLS")"
  grep -q "spawn SIM-UDID log stream" "$CALLS" || fail "no log stream call: $(cat "$CALLS")"
  [ -f "$WORKFLOWS_OUT/ios-record.pid" ] || fail "no recording pid file"
  [ -f "$WORKFLOWS_OUT/ios-unified-log.pid" ] || fail "no unified-log pid file"
  kill "$(cat "$WORKFLOWS_OUT/ios-record.pid")" "$(cat "$WORKFLOWS_OUT/ios-unified-log.pid")" 2>/dev/null || true
}

@test "record stop ends both and removes both pid files" {
  sim record start >/dev/null
  rec="$(cat "$WORKFLOWS_OUT/ios-record.pid")"
  logp="$(cat "$WORKFLOWS_OUT/ios-unified-log.pid")"
  run sim record stop
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "unified log stopped" || fail "output: $output"
  [ ! -f "$WORKFLOWS_OUT/ios-record.pid" ] || fail "recording pid file survived"
  [ ! -f "$WORKFLOWS_OUT/ios-unified-log.pid" ] || fail "unified-log pid file survived"
  sleep 1
  ! kill -0 "$rec" 2>/dev/null || fail "recording (pid $rec) still running"
  ! kill -0 "$logp" 2>/dev/null || fail "log stream (pid $logp) still running"
}

# A stop with no recording in progress must stay a no-op, log stream included.
@test "record stop without a start is a no-op" {
  run sim record stop
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "no recording in progress" || fail "output: $output"
}

@test "record stop with a recording but no unified log stops the recording alone" {
  # A recording started before the unified log existed, or whose log stream
  # never started, leaves only the recording's pid file.
  sleep 30 &
  local rec=$!
  printf '%s\n' "$rec" > "$WORKFLOWS_OUT/ios-record.pid"
  run sim record stop
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "recording stopped ($WORKFLOWS_OUT/ios.mp4)" || fail "output: $output"
  not_contains "$output" "unified log stopped" || fail "it reported a log it never had: $output"
  [ ! -f "$WORKFLOWS_OUT/ios-record.pid" ] || fail "recording pid file survived"
  ! kill -0 "$rec" 2>/dev/null || fail "recording (pid $rec) still running"
}

@test "record with anything but start or stop is a usage error" {
  local verb
  for verb in "" pause; do
    run sim record $verb
    [ "$status" -eq 1 ] || fail "record '$verb': expected exit 1, got $status: $output"
    contains "$output" "::error::usage: ios-simulator.sh record start|stop" || fail "record '$verb': $output"
  done
}

# --- shutdown and usage --------------------------------------------------

@test "shutdown shuts the selected simulator down" {
  run sim shutdown
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  grep -qx "simctl shutdown SIM-UDID" "$CALLS" || fail "calls: $(cat "$CALLS")"
}

@test "shutdown of a simulator that is already down still succeeds" {
  # It runs under `if: always()` after the suite; its failure would only hide
  # the result that matters.
  STUB_SIMCTL_STATUS=149 run sim shutdown
  [ "$status" -eq 0 ] || fail "a failed shutdown failed the step: status $status; output: $output"
}

@test "no subcommand, or an unknown one, is a usage error naming all of them" {
  local verb
  for verb in "" boot; do
    run sim $verb
    [ "$status" -eq 1 ] || fail "'$verb': expected exit 1, got $status: $output"
    contains "$output" "::error::usage: ios-simulator.sh pick | wait | install <app.tar|App.app> | record start|stop | shutdown" ||
      fail "'$verb': $output"
  done
  [ ! -s "$CALLS" ] || fail "xcrun was called: $(cat "$CALLS")"
}
