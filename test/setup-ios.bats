#!/usr/bin/env bats
# scripts/setup/ios.sh - Xcode selected and past its first launch, an iOS
# simulator runtime, CocoaPods in mise's Ruby and, with --boot, a booted
# iPhone simulator. Run against fakes of xcode-select, xcodebuild, xcrun, gem,
# pod, security and mise, in a throwaway app and HOME
# (test/setup_helper.bash); node, which reads simctl's JSON, is the real one.
#
# Covers every way out: not macOS; an unknown flag; no mise; each Xcode
# failure (none installed, the Command Line Tools selected, first launch not
# run, licence not accepted); the runtime present, downloaded, and still
# missing after the download; CocoaPods present or installed, under each
# locale (none, a non-UTF-8 one, a UTF-8 one); signing identities or none; and
# --boot reusing a booted iPhone, booting the newest existing one, creating
# one, and failing with no iPhone device type or no iOS runtime.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper
load setup_helper

setup() {
  setup_sandbox
  SCRIPT="$REPO_ROOT/scripts/setup/ios.sh"
}

ios() { run bash "$SCRIPT" "$@" </dev/null; }

RUNTIME='{"identifier":"rt.iOS-27-0","platform":"iOS","isAvailable":true,"version":"27.0"'
PHONE_TYPE='{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro","name":"iPhone 18 Pro"}'

@test "skipped entirely off macOS" {
  FAKE_OS=Linux ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "not macOS: iOS setup skipped" || fail "output: $output"
  [ -z "$(calls xcodebuild)$(calls mise)" ] || fail "did something: $(cat "$LOG")"
}

@test "a ready Mac only installs CocoaPods, pinned, under a UTF-8 locale" {
  FAKE_GEM_MISSING=1 LANG=C ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(calls gem)" "gem install cocoapods --version 1.17.0 --no-document" || fail "gem: $(calls gem)"
  grep -qx 'LANG=en_US.UTF-8' "$LOG" || fail "locale: $(cat "$LOG")"
  [ -z "$(calls xcodebuild | grep -- -downloadPlatform || true)" ] || fail "downloaded a runtime: $(calls xcodebuild)"
  contains "$output" "ok    cocoapods 1.17.0" || fail "output: $output"
  contains "$output" "iOS is ready." || fail "output: $output"
}

@test "no locale at all becomes en_US.UTF-8, and a UTF-8 one is kept" {
  unset LANG
  FAKE_GEM_MISSING=1 ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'LANG=en_US.UTF-8' "$LOG" || fail "no locale: $(cat "$LOG")"
  : >"$LOG"
  FAKE_GEM_MISSING=1 LANG=sv_SE.UTF-8 ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'LANG=sv_SE.UTF-8' "$LOG" || fail "a chosen UTF-8 locale was replaced: $(cat "$LOG")"
}

@test "CocoaPods already at the pin is left alone" {
  ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls gem)" = "gem list --installed cocoapods --version 1.17.0" ] || fail "gem: $(calls gem)"
  contains "$output" "ok    cocoapods 1.17.0" || fail "output: $output"
}

@test "the Command Line Tools selected stops with the exact admin command to run" {
  FAKE_DEVELOPER_DIR=/Library/Developer/CommandLineTools ios
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "the Command Line Tools are selected (/Library/Developer/CommandLineTools)" || fail "output: $output"
  contains "$output" "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" || fail "output: $output"
}

@test "no Xcode at all stops with where to get it" {
  FAKE_DEVELOPER_DIR="" ios
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "Xcode is not installed" || fail "output: $output"
}

@test "first launch not done stops with the exact admin command to run" {
  FAKE_FIRST_LAUNCH=1 ios
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "sudo xcodebuild -runFirstLaunch" || fail "output: $output"
}

@test "licence not accepted stops with the exact admin command to run" {
  FAKE_LICENSE=1 ios
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "sudo xcodebuild -license accept" || fail "output: $output"
}

@test "a missing simulator runtime is downloaded" {
  printf '{"runtimes":[]}' >"$WORK/runtimes.json"
  ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(calls xcodebuild)" "xcodebuild -downloadPlatform iOS" || fail "xcodebuild: $(calls xcodebuild)"
}

@test "a runtime download that still leaves no iOS runtime is reported" {
  printf '{"runtimes":[]}' >"$WORK/runtimes.json"
  printf 'case "$1" in -version) echo "Xcode 27.0" ;; esac\ntrue\n' >"$FAKEBIN/xcodebuild.impl"
  ios
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "no iOS simulator runtime after xcodebuild -downloadPlatform iOS" || fail "output: $output"
}

@test "no signing certificate is a warning, and a certificate is counted" {
  run bash -c 'bash "$1" 2>&1 >/dev/null </dev/null' _ "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "no code signing certificate on this machine" || fail "stderr: $output"
  contains "$output" "declares signed entitlements (Associated Domains, App Groups)" || fail "stderr: $output"
  FAKE_IDENTITIES='  1) ABC "Apple Development: x"
     1 valid identities found' ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "1 signing identities" || fail "output: $output"
}

@test "--boot reuses a booted iPhone" {
  printf '{"devices":{"rt.iOS-27-0":[{"name":"iPhone 18 Pro","udid":"BOOTED"}]}}' >"$WORK/booted.json"
  ios --boot
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "already booted: BOOTED" || fail "output: $output"
  [ -z "$(calls xcrun | grep 'simctl boot' || true)" ] || fail "booted another: $(calls xcrun)"
}

@test "--boot boots the newest existing iPhone" {
  printf '{"runtimes":[%s,"supportedDeviceTypes":[%s]}],"devices":{"rt.iOS-27-0":[{"name":"iPhone 17","udid":"OLD","isAvailable":true},{"name":"iPhone 18 Pro","udid":"NEW","isAvailable":true}]}}' \
    "$RUNTIME" "$PHONE_TYPE" >"$WORK/all.json"
  ios --boot
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'xcrun simctl boot NEW' "$LOG" || fail "xcrun: $(calls xcrun)"
  grep -qx 'xcrun simctl bootstatus NEW' "$LOG" || fail "xcrun: $(calls xcrun)"
  contains "$output" "booted NEW" || fail "output: $output"
}

@test "--boot creates an iPhone when none exists" {
  printf '{"runtimes":[%s,"supportedDeviceTypes":[%s]}],"devices":{}}' "$RUNTIME" "$PHONE_TYPE" >"$WORK/all.json"
  ios --boot
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'xcrun simctl create iPhone (setup) com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro rt.iOS-27-0' "$LOG" \
    || fail "xcrun: $(calls xcrun)"
  grep -qx 'xcrun simctl boot NEW-UDID' "$LOG" || fail "xcrun: $(calls xcrun)"
  contains "$output" "created NEW-UDID" || fail "output: $output"
}

@test "--boot with no iPhone device type for the runtime says so" {
  printf '{"runtimes":[%s,"supportedDeviceTypes":[]}],"devices":{}}' "$RUNTIME" >"$WORK/all.json"
  ios --boot
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "no iPhone device type for rt.iOS-27-0" || fail "output: $output"
}

@test "--boot with no available iOS runtime in the list stops instead of booting nothing" {
  printf '{"runtimes":[],"devices":{}}' >"$WORK/all.json"
  ios --boot
  [ "$status" -ne 0 ] || fail "succeeded: $output"
  [ -z "$(calls xcrun | grep -E 'simctl (boot|create)' || true)" ] || fail "carried on: $(calls xcrun)"
  not_contains "$output" "iOS is ready." || fail "output: $output"
}

@test "without mise it names the script that installs it" {
  rm "$FAKEBIN/mise"
  ios
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "mise is not installed. Run: bash node_modules/@blinkbitcoin/app-tooling/setup/toolchain.sh" || fail "output: $output"
}

@test "an unknown flag is refused" {
  ios --yess
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "unknown argument: --yess" || fail "output: $output"
}
