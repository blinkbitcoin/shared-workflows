#!/usr/bin/env bats
# scripts/self/test-fastlane.sh - runs the lanes' Ruby unit tests under Bundler.
# `bundle` is a stub that records its argv, its Gemfile and its install path, and
# the working directory it was started in: those are the whole job of the
# wrapper. The tests themselves run in the `Unit / Fastlane` job.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/bundle.log"
  : > "$WORKFLOWS_TEST_LOG"
  cat > "$STUB/bundle" <<'SH'
#!/usr/bin/env bash
printf 'bundle: %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
printf 'gemfile: %s\n' "${BUNDLE_GEMFILE-unset}" >> "$WORKFLOWS_TEST_LOG"
printf 'path: %s\n' "${BUNDLE_PATH-unset}" >> "$WORKFLOWS_TEST_LOG"
printf 'cwd: %s\n' "$PWD" >> "$WORKFLOWS_TEST_LOG"
exit "${FAKE_BUNDLE_EXIT:-0}"
SH
  chmod +x "$STUB/bundle"
  export PATH="$STUB:$PATH"
}

@test "it installs the test gems, then runs the lanes' tests from the package" {
  run bash "$REPO_ROOT/scripts/self/test-fastlane.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'bundle: install --quiet' "$WORKFLOWS_TEST_LOG" || fail "no install: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx 'bundle: exec ruby -Ifastlane/test fastlane/test/lanes_test.rb' "$WORKFLOWS_TEST_LOG" \
    || fail "the tests were not run: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "gemfile: $REPO_ROOT/packages/app-tooling/fastlane/test/Gemfile" "$WORKFLOWS_TEST_LOG" || fail "wrong Gemfile: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "path: $REPO_ROOT/.gems" "$WORKFLOWS_TEST_LOG" || fail "gems are not kept in .gems: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "cwd: $REPO_ROOT/packages/app-tooling" "$WORKFLOWS_TEST_LOG" || fail "tests did not start in the package: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "minitest options are passed through to the run, not to the install" {
  run bash "$REPO_ROOT/scripts/self/test-fastlane.sh" -n /real_fastlane/
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'bundle: exec ruby -Ifastlane/test fastlane/test/lanes_test.rb -n /real_fastlane/' "$WORKFLOWS_TEST_LOG" \
    || fail "options lost: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx 'bundle: install --quiet' "$WORKFLOWS_TEST_LOG" || fail "install changed: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a failing install stops before any test runs" {
  FAKE_BUNDLE_EXIT=7 run bash "$REPO_ROOT/scripts/self/test-fastlane.sh"
  [ "$status" -eq 7 ] || fail "expected 7, got $status: $output"
  ! grep -q 'bundle: exec' "$WORKFLOWS_TEST_LOG" || fail "tests ran after a failed install"
}

@test "it runs from any directory, by a relative path" {
  cd "$REPO_ROOT/scripts" || fail "cd"
  run bash self/test-fastlane.sh
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "cwd: $REPO_ROOT/packages/app-tooling" "$WORKFLOWS_TEST_LOG" || fail "wrong directory: $(cat "$WORKFLOWS_TEST_LOG")"
}
