#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# `sdkmanager` is stubbed: what is under test is where the script *finds* the
# binary, what it asks it for, and how it retries - not Google's CDN. The stub
# appends its argv to a log and fails its first $WORKFLOWS_TEST_FAILURES invocations,
# so a test can assert both the request and the number of attempts.
load test_helper

# make_sdk [REL_BIN_DIR] - a fake SDK root with a stub sdkmanager at REL_BIN_DIR
# (empty installs no binary at all). Sets SDK and SDK_LOG.
make_sdk() {
  local bin_dir="${1-cmdline-tools/latest/bin}"
  SDK="$BATS_TEST_TMPDIR/sdk"
  SDK_LOG="$SDK/sdkmanager.log"
  rm -rf "$SDK"
  mkdir -p "$SDK"
  : > "$SDK_LOG"
  if [ -n "$bin_dir" ]; then
    mkdir -p "$SDK/$bin_dir"
    cat > "$SDK/$bin_dir/sdkmanager" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SDK_LOG"
attempts=\$(grep -c . "$SDK_LOG")
if [ "\$attempts" -le "\${WORKFLOWS_TEST_FAILURES:-0}" ]; then
  echo "Error on ZipFile unknown archive" >&2
  exit 1
fi
exit 0
SH
    as_fakes "$SDK/$bin_dir/sdkmanager"
  fi
  # The download cache the script purges between attempts, so a test can watch
  # it go.
  mkdir -p "$SDK/.downloadIntermediates"
  export ANDROID_HOME="$SDK"
}

# install ARGS... - run the script against the fake SDK root. HOME points at it
# too, so the `$HOME/.android/cache` purge stays inside the test's tmpdir.
install() {
  run env HOME="$SDK" bash "$REPO_ROOT/scripts/ci/android-sdk-install.sh" "$@"
}

calls() { grep -c . "$SDK_LOG"; }

# ANDROID_HOME is unset rather than trusted: a developer machine with a real
# Android SDK would otherwise satisfy every lookup and these tests would pass
# without ever running the stub.
setup() {
  unset ANDROID_HOME ANDROID_SDK_ROOT ANDROID_SDK_RETRIES WORKFLOWS_TEST_FAILURES
  make_sdk
}

# The regression this file exists for: the first cut called a bare `sdkmanager`,
# which is not on the runners' PATH, so every attempt died with "command not
# found" in milliseconds and the retry loop hid it.
@test "runs the sdkmanager inside the SDK root, not one from PATH" {
  PATH=/usr/bin:/bin install emulator
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$SDK_LOG")" = "--install emulator --channel=0" ] \
    || fail "unexpected sdkmanager call: $(cat "$SDK_LOG")"
  contains "$output" "Installed: emulator" || fail "unexpected message: $output"
  traced "$output" "Install Android SDK packages (emulator)" || fail "the install was not timed: $output"
}

@test "finds sdkmanager in a versioned cmdline-tools directory" {
  make_sdk cmdline-tools/13.0/bin
  install emulator
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls)" -eq 1 ] || fail "expected 1 call, got $(calls)"
}

@test "finds sdkmanager in the retired tools/bin layout" {
  make_sdk tools/bin
  install emulator
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls)" -eq 1 ] || fail "expected 1 call, got $(calls)"
}

@test "falls back to ANDROID_SDK_ROOT when ANDROID_HOME is unset" {
  ANDROID_HOME='' ANDROID_SDK_ROOT="$SDK" install emulator
  [ "$status" -eq 0 ] || fail "exited $status: $output"
}

@test "neither ANDROID_HOME nor ANDROID_SDK_ROOT set is fatal" {
  ANDROID_HOME='' ANDROID_SDK_ROOT='' install emulator
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "neither ANDROID_HOME nor ANDROID_SDK_ROOT is set" \
    || fail "unexpected message: $output"
}

@test "retries after purging the download cache, then succeeds" {
  WORKFLOWS_TEST_FAILURES=2 install emulator
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls)" -eq 3 ] || fail "expected 3 attempts, got $(calls)"
  contains "$output" "retry 1 of 2" || fail "first retry unannounced: $output"
  contains "$output" "retry 2 of 2" || fail "second retry unannounced: $output"
  # The half-written archive is replayed from this directory, so an unpurged
  # retry fails identically and the retry budget buys nothing.
  [ ! -d "$SDK/.downloadIntermediates" ] \
    || fail "the download cache survived the retry"
}

@test "gives up after ANDROID_SDK_RETRIES retries" {
  WORKFLOWS_TEST_FAILURES=99 ANDROID_SDK_RETRIES=1 install emulator
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  [ "$(calls)" -eq 2 ] || fail "expected 2 attempts, got $(calls)"
  contains "$output" "could not install 'emulator' in 2 attempts" \
    || fail "unexpected message: $output"
}

# A missing binary is a broken runner image, not a flaky download: retrying it
# just burns the budget and buries the real cause.
@test "an SDK root with no sdkmanager fails immediately, without retrying" {
  make_sdk ''
  install emulator
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "no sdkmanager under $SDK" || fail "unexpected message: $output"
  not_contains "$output" "retry" || fail "a missing binary was retried: $output"
}

@test "a call that names no package is a usage error (exit 2)" {
  install
  [ "$status" -eq 2 ] || fail "exited $status: $output"
  contains "$output" "usage:" || fail "unexpected message: $output"
  [ "$(calls)" -eq 0 ] || fail "ran sdkmanager anyway: $(cat "$SDK_LOG")"
}
