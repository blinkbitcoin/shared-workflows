#!/usr/bin/env bats
# scripts/security/run-job.sh - runs one of the consumer's security runners,
# scripts/security/<job>.sh, and insists it reported. Covers every way out of
# it: a runner that writes its SARIF (in the default directory and in the one
# SECURITY_DIR names), and each failure - no node, no job named, no runner for
# the job, a runner that crashes, and a runner that exits 0 having written no
# SARIF or an empty one. The runners live in the consumer; each test hands in a
# stand-in.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# A throwaway consumer checkout. $1 names the directory; the script's body is
# read from stdin so a test can hand it any behaviour, including no output at
# all. Nothing is copied from the template: these are stand-ins for the
# consumer's files, not second copies of them.
consumer_with() {
  local dir="$BATS_TEST_TMPDIR/$1" file="$2"
  mkdir -p "$dir/$(dirname "$file")"
  cat > "$dir/$file"
  printf '%s' "$dir"
}

# A PATH holding only dirname, which the script needs to find its library, so
# that require_cmd cannot find node.
path_without_node() {
  local bin="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bin"
  ln -sf "$(command -v dirname)" "$bin/dirname"
  printf '%s' "$bin"
}

@test "run-job.sh runs the consumer's runner and reports where the SARIF landed" {
  local consumer
  consumer="$(consumer_with good scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${SECURITY_DIR:-.security}"
mkdir -p "$out"
printf '{"version":"2.1.0","runs":[]}' > "$out/deps.sarif"
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  [ -s "$consumer/.security/deps.sarif" ] || fail "no SARIF at $consumer/.security/deps.sarif"
}

@test "run-job.sh fails by name when the consumer ships no runner for the job" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/norunner"
  mkdir -p "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" code
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/code.sh' || fail "the error does not name the missing runner: $output"
  contains "$output" 'security-policy.json' || fail "the error does not say how to switch the job off: $output"
}

# A runner that exits 0 without writing its SARIF would reach the verdict as
# nothing at all, and the verdict cannot tell "found nothing" from "reported
# nothing". So the bridge insists on the file.
@test "run-job.sh fails when a runner exits 0 having reported nothing" {
  local consumer
  consumer="$(consumer_with quiet scripts/security/policy.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 1 ] || fail "a silent runner passed: $output"
  contains "$output" 'policy.sarif' || fail "the error does not name the SARIF that is missing: $output"
}

@test "run-job.sh hands back a crashing runner's exit code" {
  local consumer
  consumer="$(consumer_with crash scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
echo "osv-scanner: bad config" >&2
exit 3
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 3 ] || fail "expected the runner's own exit code 3, got $status: $output"
}

@test "run-job.sh fails when node is not on the PATH" {
  run env PATH="$(path_without_node)" "$BASH" "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: node' || fail "the error does not name node: $output"
}

@test "run-job.sh without a job name fails with its usage" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/nojob"
  mkdir -p "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/security/run-job.sh"
  [ "$status" -ne 0 ] || fail "a call naming no job passed: $output"
  contains "$output" 'usage: run-job.sh JOB' || fail "the error does not show the usage: $output"
}

@test "run-job.sh fails when a runner leaves an empty SARIF" {
  local consumer
  consumer="$(consumer_with empty scripts/security/code.sh <<'EOF'
#!/usr/bin/env bash
mkdir -p .security
: > .security/code.sarif
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" code
  [ "$status" -eq 1 ] || fail "an empty SARIF was read as a report: $output"
  contains "$output" '::error::scripts/security/code.sh exited 0 but left no .security/code.sarif' \
    || fail "the error does not name the runner and the SARIF: $output"
}

@test "run-job.sh looks for the SARIF in the directory SECURITY_DIR names" {
  local consumer
  consumer="$(consumer_with elsewhere scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -d "$SECURITY_DIR" ] || { echo "run-job.sh did not create $SECURITY_DIR" >&2; exit 4; }
printf '{"version":"2.1.0","runs":[]}' > "$SECURITY_DIR/deps.sarif"
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export SECURITY_DIR="reports/security"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  [ -s "$consumer/reports/security/deps.sarif" ] || fail "no SARIF at $consumer/reports/security/deps.sarif"
  [ ! -e "$consumer/.security" ] || fail "the default directory was used although SECURITY_DIR was set"
  contains "$output" 'deps: reports/security/deps.sarif' || fail "the log does not say where the SARIF landed: $output"
}
