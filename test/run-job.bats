#!/usr/bin/env bats
# scripts/security/run-job.sh - runs one of the security runners beside it,
# scripts/security/<job>.sh, against the consumer, and insists it reported.
# Covers every way out of it: a runner that writes its SARIF (in the default
# directory and in the one SECURITY_DIR names), and each failure - no node, no
# job named, a job with no runner, a runner that crashes, and a runner that
# exits 0 having written no SARIF or an empty one.
#
# The runners are this repository's own, so most cases run a real one
# (policy.sh, or dependencies.sh with a fake osv-scanner on PATH) against a
# throwaway consumer. The one case that needs a runner to exit with a status of
# its choosing uses a copy of run-job.sh with a stand-in runner beside it.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  # A runner reads all of these; a value leaking in from the caller's shell
  # (a CI runner sets CI and GITHUB_WORKSPACE) would decide the outcome.
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY
  local name
  for name in $(compgen -e); do
    case "$name" in SECURITY_*) unset "$name" ;; esac
  done
  REAL_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
}

# An empty consumer checkout named $1; prints its path.
consumer() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# A fake osv-scanner, first on PATH, whose body is read from stdin.
fake_osv_scanner() {
  local bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$bin"
  {
    printf '#!/usr/bin/env bash\n'
    cat
  } > "$bin/osv-scanner"
  as_fakes "$bin/osv-scanner"
  export PATH="$bin:$PATH"
}

# A copy of run-job.sh and the library it sources, with a stand-in runner
# named $1 beside it whose body is read from stdin. Prints the copy's run-job.sh.
layout_with_runner() {
  local root="$BATS_TEST_TMPDIR/layout" job="$1"
  mkdir -p "$root/scripts/security" "$root/scripts/lib"
  cp "$REPO_ROOT/scripts/security/run-job.sh" "$root/scripts/security/run-job.sh"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$root/scripts/lib/common.sh"
  cat > "$root/scripts/security/$job.sh"
  printf '%s' "$root/scripts/security/run-job.sh"
}

# A PATH holding only dirname, which the script needs to find its library, so
# that require_cmd cannot find node.
path_without_node() {
  local bin="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bin"
  ln -sf "$(command -v dirname)" "$bin/dirname"
  printf '%s' "$bin"
}

@test "run-job.sh runs the real runner against the consumer and reports where the SARIF landed" {
  GITHUB_WORKSPACE="$(consumer good)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  [ -s "$GITHUB_WORKSPACE/.security/policy.sarif" ] || fail "no SARIF at $GITHUB_WORKSPACE/.security/policy.sarif"
  grep -q '"name": "policy"' "$GITHUB_WORKSPACE/.security/policy.sarif" \
    || fail "the SARIF is not the policy runner's: $(cat "$GITHUB_WORKSPACE/.security/policy.sarif")"
  contains "$output" 'policy: .security/policy.sarif' || fail "the log does not say where the SARIF landed: $output"
  traced "$output" "Run the policy scanner" || fail "the scanner was not timed: $output"
}

@test "run-job.sh looks for the SARIF in the directory SECURITY_DIR names" {
  fake_osv_scanner <<'EOF'
while [ $# -gt 0 ]; do
  if [ "$1" = --output-file ]; then
    printf '{"version":"2.1.0","runs":[]}' > "$2"
    exit 0
  fi
  shift
done
echo "fake osv-scanner: no --output-file" >&2
exit 9
EOF
  GITHUB_WORKSPACE="$(consumer elsewhere)"
  export GITHUB_WORKSPACE
  export SECURITY_DIR="reports/security"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" dependencies
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  [ -s "$GITHUB_WORKSPACE/reports/security/dependencies.sarif" ] \
    || fail "no SARIF at $GITHUB_WORKSPACE/reports/security/dependencies.sarif"
  [ ! -e "$GITHUB_WORKSPACE/.security" ] || fail "the default directory was used although SECURITY_DIR was set"
  contains "$output" 'dependencies: reports/security/dependencies.sarif' \
    || fail "the log does not say where the SARIF landed: $output"
}

@test "run-job.sh fails when node is not on the PATH" {
  GITHUB_WORKSPACE="$(consumer no-node)"
  export GITHUB_WORKSPACE
  run env PATH="$(path_without_node)" "$BASH" "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: node' || fail "the error does not name node: $output"
}

@test "run-job.sh without a job name fails with its usage" {
  GITHUB_WORKSPACE="$(consumer nojob)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/run-job.sh"
  [ "$status" -ne 0 ] || fail "a call naming no job passed: $output"
  contains "$output" 'usage: run-job.sh JOB' || fail "the error does not show the usage: $output"
}

@test "run-job.sh refuses anything but the nine job names, before touching the consumer" {
  local name
  GITHUB_WORKSPACE="$(consumer refused)"
  export GITHUB_WORKSPACE
  for name in nosuchjob ../security/policy lib/runner settings verdict run-job ''; do
    run bash "$REPO_ROOT/scripts/security/run-job.sh" "$name"
    [ "$status" -eq 1 ] || fail "'$name' was accepted as a job, status $status: $output"
    [ -z "$name" ] || contains "$output" "::error::not a security job: $name" \
      || fail "the error does not name '$name': $output"
  done
  [ ! -e "$GITHUB_WORKSPACE/.security" ] || fail "a refused job still created the SARIF directory"
}

# A finding never fails a runner, so a non-zero exit is a crash, and errexit
# hands it back rather than the bridge's own "left no SARIF".
@test "run-job.sh fails when the real runner's scanner crashes" {
  fake_osv_scanner <<'EOF'
echo "osv-scanner: bad config" >&2
exit 2
EOF
  GITHUB_WORKSPACE="$(consumer crash)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/run-job.sh" dependencies
  [ "$status" -ne 0 ] || fail "a crashed scanner passed: $output"
  contains "$output" 'osv-scanner: bad config' || fail "the scanner's own error never reached the log: $output"
  not_contains "$output" 'exited 0 but left no' || fail "a crash was reported as a silent runner: $output"
}

@test "run-job.sh hands back a crashing runner's own exit code" {
  local script
  script="$(layout_with_runner code <<'EOF'
#!/usr/bin/env bash
echo "stand-in runner: crashed" >&2
exit 3
EOF
)"
  GITHUB_WORKSPACE="$(consumer crash-code)"
  export GITHUB_WORKSPACE
  run bash "$script" code
  [ "$status" -eq 3 ] || fail "expected the runner's own exit code 3, got $status: $output"
  contains "$output" 'stand-in runner: crashed' || fail "the runner's own error never reached the log: $output"
}

# A runner that exits 0 without writing its SARIF would reach the verdict as
# nothing at all, and the verdict cannot tell "found nothing" from "reported
# nothing". So the bridge insists on the file.
@test "run-job.sh fails when a runner exits 0 having reported nothing" {
  fake_osv_scanner <<'EOF'
exit 0
EOF
  GITHUB_WORKSPACE="$(consumer quiet)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/run-job.sh" dependencies
  [ "$status" -eq 1 ] || fail "a silent runner passed: $output"
  contains "$output" '::error::dependencies.sh exited 0 but left no .security/dependencies.sarif' \
    || fail "the error does not name the runner and the SARIF: $output"
}

@test "run-job.sh fails when a runner leaves an empty SARIF" {
  fake_osv_scanner <<'EOF'
while [ $# -gt 0 ]; do
  if [ "$1" = --output-file ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 9
EOF
  GITHUB_WORKSPACE="$(consumer empty)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/run-job.sh" dependencies
  [ "$status" -eq 1 ] || fail "an empty SARIF was read as a report: $status / $output"
  [ -e "$GITHUB_WORKSPACE/.security/dependencies.sarif" ] || fail "the fake scanner did not leave its empty file"
  contains "$output" '::error::dependencies.sh exited 0 but left no .security/dependencies.sarif' \
    || fail "the error does not name the runner and the SARIF: $output"
}
