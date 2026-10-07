#!/usr/bin/env bats
load test_helper

setup() {
  stub_cmd sudo 'echo "sudo must not be invoked off a Linux GitHub Actions runner" >&2; exit 99'
  stub_cmd udevadm
  unset GITHUB_ACTIONS RUNNER_OS WORKFLOWS_FORCE_RUNNER_SCRIPTS
}

@test "skips with a notice and never calls sudo when GITHUB_ACTIONS is unset" {
  run bash "$REPO_ROOT/scripts/ci/enable-kvm.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]] || fail "assertion failed; output: $output"
}

@test "skips with a notice and never calls sudo when RUNNER_OS is not Linux" {
  GITHUB_ACTIONS=true RUNNER_OS=macOS run bash "$REPO_ROOT/scripts/ci/enable-kvm.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]] || fail "assertion failed; output: $output"
}

@test "WORKFLOWS_FORCE_RUNNER_SCRIPTS=1 bypasses the guard (and would hit the sudo stub)" {
  WORKFLOWS_FORCE_RUNNER_SCRIPTS=1 run bash "$REPO_ROOT/scripts/ci/enable-kvm.sh"
  [ "$status" -eq 99 ]
  [[ "$output" == *"sudo must not be invoked"* ]] || fail "assertion failed; output: $output"
}
