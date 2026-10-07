#!/usr/bin/env bats
# android-emulator.sh is device-bound, so only the pure plumbing is asserted
# here: which ports `prepare` reverses into the emulator. `adb` is stubbed and
# every invocation logged.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/consumer"
  export WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$GITHUB_WORKSPACE" "$WORKFLOWS_OUT"
  apk="$BATS_TEST_TMPDIR/app-debug.apk"
  : > "$apk"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ADB_LOG="$BATS_TEST_TMPDIR/adb.log"
  export ADB_LOG
  cat > "$bin/adb" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ADB_LOG"
STUB
  chmod +x "$bin/adb"
  PATH="$bin:$PATH"
  export PATH
  : > "$ADB_LOG"
}

@test "prepare reverses the Metro port and the default mock-API port 8082" {
  run bash "$REPO_ROOT/scripts/e2e/android-emulator.sh" prepare "$apk"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "reverse tcp:8081 tcp:8081" "$ADB_LOG" || fail "Metro's port was not reversed: $(cat "$ADB_LOG")"
  grep -qx "reverse tcp:8082 tcp:8082" "$ADB_LOG" || fail "the default mock-API port 8082 was not reversed: $(cat "$ADB_LOG")"
  ! grep -qx "reverse tcp:4000 tcp:4000" "$ADB_LOG" || fail "the retired default 4000 was reversed: $(cat "$ADB_LOG")"
  grep -qx "install -r $apk" "$ADB_LOG" || fail "the APK was not installed: $(cat "$ADB_LOG")"
  traced "$output" "Install app on emulator" || fail "the install was not timed: $output"
}

@test "WORKFLOWS_MOCK_API_PORT overrides the reversed mock-API port" {
  WORKFLOWS_MOCK_API_PORT=5001 run bash "$REPO_ROOT/scripts/e2e/android-emulator.sh" prepare "$apk"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "reverse tcp:5001 tcp:5001" "$ADB_LOG" || fail "the override 5001 was not reversed: $(cat "$ADB_LOG")"
  ! grep -qx "reverse tcp:8082 tcp:8082" "$ADB_LOG" || fail "the default 8082 was reversed despite WORKFLOWS_MOCK_API_PORT=5001: $(cat "$ADB_LOG")"
}

@test "an empty WORKFLOWS_MOCK_API_PORT reverses only Metro" {
  WORKFLOWS_MOCK_API_PORT= run bash "$REPO_ROOT/scripts/e2e/android-emulator.sh" prepare "$apk"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(grep -c '^reverse ' "$ADB_LOG")" -eq 1 ] || fail "expected one reverse, got: $(cat "$ADB_LOG")"
  grep -qx "reverse tcp:8081 tcp:8081" "$ADB_LOG" || fail "Metro's port was not reversed: $(cat "$ADB_LOG")"
}
