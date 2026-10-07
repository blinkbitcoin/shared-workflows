#!/usr/bin/env bats
load test_helper

setup() {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo must not be invoked off a Linux GitHub Actions runner" >&2
exit 99
EOF
  chmod +x "$fakebin/sudo"
  export PATH="$fakebin:$PATH"
  unset GITHUB_ACTIONS RUNNER_OS WORKFLOWS_FORCE_RUNNER_SCRIPTS
}

@test "skips with a notice and never calls sudo when GITHUB_ACTIONS is unset" {
  run bash "$REPO_ROOT/scripts/ci/free-disk.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]] || fail "assertion failed; output: $output"
}

@test "skips with a notice and never calls sudo when RUNNER_OS is not Linux" {
  GITHUB_ACTIONS=true RUNNER_OS=macOS run bash "$REPO_ROOT/scripts/ci/free-disk.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]] || fail "assertion failed; output: $output"
}

@test "WORKFLOWS_FORCE_RUNNER_SCRIPTS=1 bypasses the guard (and would hit the sudo stub)" {
  WORKFLOWS_FORCE_RUNNER_SCRIPTS=1 run bash "$REPO_ROOT/scripts/ci/free-disk.sh"
  [ "$status" -eq 99 ]
  [[ "$output" == *"sudo must not be invoked"* ]] || fail "assertion failed; output: $output"
}

@test "on a Linux runner the cleanup runs in one timed group, between two disk reports" {
  stub_cmd sudo
  stub_cmd df 'echo "disk report"'
  GITHUB_ACTIONS=true RUNNER_OS=Linux run bash "$REPO_ROOT/scripts/ci/free-disk.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(stub_calls sudo)" "rm -rf /usr/share/dotnet /opt/ghc /usr/local/.ghcup" || fail "sudo calls: $(stub_calls sudo)"
  [ "$(stub_calls df)" = "-h /
-h /" ] || fail "df calls: $(stub_calls df)"
  traced "$output" "Free disk space" || fail "the cleanup was not timed: $output"
}
