#!/usr/bin/env bats
# scripts/security/verdict.sh - runs the consumer's merge,
# scripts/security/verdict.mjs, over the scanners' SARIF, and writes the report
# to the step log and the run summary. Covers every way out of it: a failing
# and a passing merge (its exit code handed back either way, its error stream
# kept in the report, the summary on stdout when there is no run summary), the
# directory SECURITY_DIR names, and each failure - no node, no merge, no SARIF
# directory, and a directory that holds no SARIF. The merge lives in the
# consumer; each test hands in a stand-in.
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

@test "verdict.sh runs the consumer's merge, prints it, and keeps its exit code" {
  local consumer
  consumer="$(consumer_with fails scripts/security/verdict.mjs <<'EOF'
console.log('deps: 1 finding(s), highest high');
console.log('security: fail, highest high, 1 finding(s), 0 suppressed, 0 job(s) skipped');
process.exit(1);
EOF
)"
  mkdir -p "$consumer/.security"
  printf '{"version":"2.1.0","runs":[]}' > "$consumer/.security/deps.sarif"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "the verdict's exit code was not handed back: $status / $output"
  contains "$output" 'security: fail' || fail "the report never reached the log: $output"
  grep -q 'security: fail' "$BATS_TEST_TMPDIR/summary.md" || fail "the report never reached the run summary"
  grep -q '^## Security' "$BATS_TEST_TMPDIR/summary.md" || fail "the summary block has no heading"
}

@test "verdict.sh refuses to report a clean run when no scanner reported at all" {
  local consumer
  consumer="$(consumer_with empty scripts/security/verdict.mjs <<'EOF'
console.log('security: pass');
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "an empty .security/ produced a verdict: $output"
  contains "$output" 'no SARIF files' || fail "the error does not say what was missing: $output"
}

@test "verdict.sh fails by name when the consumer ships no merge" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/nomerge"
  mkdir -p "$GITHUB_WORKSPACE/.security"
  printf '{}' > "$GITHUB_WORKSPACE/.security/deps.sarif"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/verdict.mjs' || fail "the error does not name the missing file: $output"
}

@test "verdict.sh fails when node is not on the PATH" {
  run env PATH="$(path_without_node)" "$BASH" "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: node' || fail "the error does not name node: $output"
}

@test "verdict.sh refuses a SARIF directory that holds no SARIF" {
  local consumer
  consumer="$(consumer_with no-sarif scripts/security/verdict.mjs <<'EOF'
console.log('security: pass');
EOF
)"
  mkdir -p "$consumer/.security"
  printf 'not a report' > "$consumer/.security/notes.txt"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "a directory without SARIF produced a verdict: $output"
  contains "$output" '::error::no SARIF files in .security' || fail "the error does not name the directory: $output"
  not_contains "$output" 'security: pass' || fail "the merge ran although nothing was reported: $output"
}

@test "verdict.sh passes a clean merge, keeping its error stream in the report, on stdout without a run summary" {
  local consumer
  consumer="$(consumer_with passes scripts/security/verdict.mjs <<'EOF'
console.error('code: skipped, switched off');
console.log('security: pass, 0 finding(s)');
EOF
)"
  mkdir -p "$consumer/.security"
  printf '{"version":"2.1.0","runs":[]}' > "$consumer/.security/deps.sarif"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "a passing merge failed the step: $status / $output"
  contains "$output" 'code: skipped, switched off' || fail "the merge's error stream was dropped: $output"
  contains "$output" '## Security' || fail "without a run summary the block did not go to stdout: $output"
  contains "$output" 'security: pass, 0 finding(s)' || fail "the report never reached the log: $output"
}

@test "verdict.sh reads the SARIF directory SECURITY_DIR names and hands it to the merge" {
  local consumer
  consumer="$(consumer_with elsewhere scripts/security/verdict.mjs <<'EOF'
console.log(`merged ${process.argv[2]}`);
EOF
)"
  mkdir -p "$consumer/reports/security"
  printf '{"version":"2.1.0","runs":[]}' > "$consumer/reports/security/deps.sarif"
  export GITHUB_WORKSPACE="$consumer"
  export SECURITY_DIR="reports/security"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "verdict.sh failed: $output"
  contains "$output" 'merged reports/security' || fail "the merge was not handed SECURITY_DIR: $output"
}
