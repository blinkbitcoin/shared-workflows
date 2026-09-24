#!/usr/bin/env bats
# ios-simulator.sh `install` pre-approves every URL scheme the app declares, so
# `simctl openurl` never raises iOS's "Open in <app>?" alert. That alert is what
# killed the XCTest driver mid-suite (run 36049645029 in
# react-native-mobile-template) and queued unanswerable alerts for the retry;
# these cases pin that each declared scheme gets its approval, and that an app
# with none is not an error.
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$WORKFLOWS_OUT"
  export WORKFLOWS_SIM_UDID=SIM-UDID
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

install_app() { run bash "$REPO_ROOT/scripts/e2e/ios-simulator.sh" install "${1:-$app}"; }

approval() { # <scheme>
  printf 'simctl spawn SIM-UDID defaults write com.apple.launchservices.schemeapproval com.apple.CoreSimulator.CoreSimulatorBridge-->%s -string com.example.app' "$1"
}

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
