#!/usr/bin/env bats
# scripts/security/verdict.sh - runs the merge,
# packages/app-tooling/lib/security-verdict.mjs, over the consumer's SARIF, and
# writes the report to the step log and the run summary. Covers every way out
# of it: a clean run that passes, a blocking finding that exits 1, a merge
# failure whose own exit code and error stream are handed back, the summary on
# stdout when there is no run summary, the merge's annotations kept in the log
# and out of the summary, a summary block written even when every line was an
# annotation, the directory SECURITY_DIR names, the script called by a relative
# path, and each refusal - no node, no SARIF directory, and a directory that
# holds no SARIF.
#
# The real merge answers every case it can produce, over SARIF written by
# security-sarif.mjs. The one output it never produces (annotations and
# nothing else) comes from a copy of verdict.sh with a stand-in merge.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  # The merge reads SECURITY_* for its threshold and prints annotations only
  # under GITHUB_ACTIONS; a value leaking in from the caller's shell would
  # decide the outcome.
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY GITHUB_ACTIONS
  local name
  for name in $(compgen -e); do
    case "$name" in SECURITY_*) unset "$name" ;; esac
  done
  SARIF_CLI="$REPO_ROOT/packages/app-tooling/lib/security-sarif.mjs"
}

# An empty consumer checkout named $1; prints its path.
consumer() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# sarif FILE JOB - write JOB's SARIF to FILE from finding lines on stdin, in
# security-sarif.mjs's `verb<TAB>rule<TAB>file:line<TAB>message` form; no
# lines is a clean run.
sarif() {
  mkdir -p "$(dirname "$1")"
  node "$SARIF_CLI" lines "$2" > "$1"
}

# A copy of verdict.sh and its library, with a stand-in merge (read from stdin)
# where packages/app-tooling/lib/security-verdict.mjs would be. Prints the
# copy's verdict.sh.
layout_with_merge() {
  local root="$BATS_TEST_TMPDIR/layout"
  mkdir -p "$root/scripts/security" "$root/scripts/lib" "$root/packages/app-tooling/lib"
  cp "$REPO_ROOT/scripts/security/verdict.sh" "$root/scripts/security/verdict.sh"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$root/scripts/lib/common.sh"
  cat > "$root/packages/app-tooling/lib/security-verdict.mjs"
  printf '%s' "$root/scripts/security/verdict.sh"
}

# A PATH holding only dirname, which the script needs to find its library, so
# that require_cmd cannot find node.
path_without_node() {
  local bin="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bin"
  ln -sf "$(command -v dirname)" "$bin/dirname"
  printf '%s' "$bin"
}

@test "verdict.sh passes a clean run and writes the report to the log and the run summary" {
  GITHUB_WORKSPACE="$(consumer clean)"
  export GITHUB_WORKSPACE
  sarif "$GITHUB_WORKSPACE/.security/dependencies.sarif" dependencies < /dev/null
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "a clean run failed the step: $status / $output"
  contains "$output" 'dependencies: clean' || fail "the report never reached the log: $output"
  contains "$output" 'security: pass' || fail "a clean run did not read as a pass: $output"
  grep -q '^## Security' "$GITHUB_STEP_SUMMARY" || fail "the summary block has no heading"
  grep -q 'security: pass' "$GITHUB_STEP_SUMMARY" || fail "the report never reached the run summary"
}

@test "verdict.sh writes the summary block to stdout when there is no run summary" {
  GITHUB_WORKSPACE="$(consumer stdout)"
  export GITHUB_WORKSPACE
  sarif "$GITHUB_WORKSPACE/.security/code.sarif" code < /dev/null
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "a clean run failed the step: $status / $output"
  contains "$output" '## Security' || fail "without a run summary the block did not go to stdout: $output"
}

@test "verdict.sh exits 1 on a blocking finding, annotating the log and keeping :: lines out of the summary" {
  GITHUB_WORKSPACE="$(consumer blocking)"
  export GITHUB_WORKSPACE
  printf 'FAIL\tjs/eval\tsrc/a.ts:3\teval of user input\n' \
    | sarif "$GITHUB_WORKSPACE/.security/code.sarif" code
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export GITHUB_ACTIONS=true
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "a blocking finding did not fail the step: $status / $output"
  contains "$output" 'security: fail, highest high' || fail "the report never reached the log: $output"
  contains "$output" '::error file=src/a.ts,line=3' || fail "the annotation never reached the log, so the runner cannot show it: $output"
  [ -z "$(grep '^::' "$GITHUB_STEP_SUMMARY" || true)" ] \
    || fail "a workflow command leaked into the run summary: $(cat "$GITHUB_STEP_SUMMARY")"
  grep -q 'security: fail' "$GITHUB_STEP_SUMMARY" || fail "the report itself was dropped from the summary"
}

@test "verdict.sh reports a finding below the threshold without failing" {
  GITHUB_WORKSPACE="$(consumer below)"
  export GITHUB_WORKSPACE
  printf '{ "severity": "critical" }\n' > "$GITHUB_WORKSPACE/security-settings.json"
  printf 'FAIL\tjs/eval\tsrc/a.ts:3\teval of user input\n' \
    | sarif "$GITHUB_WORKSPACE/.security/code.sarif" code
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "a finding below the consumer's threshold failed the step: $status / $output"
  contains "$output" 'code: 1 finding(s), highest high' || fail "the finding was dropped from the report: $output"
}

@test "verdict.sh hands back the merge's own exit code and keeps its error stream in the report" {
  GITHUB_WORKSPACE="$(consumer unreadable)"
  export GITHUB_WORKSPACE
  mkdir -p "$GITHUB_WORKSPACE/.security"
  printf 'not a report' > "$GITHUB_WORKSPACE/.security/code.sarif"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 2 ] || fail "expected the merge's own exit code 2, got $status: $output"
  contains "$output" '.security/code.sarif: not valid JSON' || fail "the merge's error stream was dropped: $output"
  grep -q 'not valid JSON' "$GITHUB_STEP_SUMMARY" || fail "the merge's error never reached the run summary"
}

@test "verdict.sh reads the SARIF directory SECURITY_DIR names" {
  GITHUB_WORKSPACE="$(consumer elsewhere)"
  export GITHUB_WORKSPACE
  sarif "$GITHUB_WORKSPACE/reports/security/policy.sarif" policy < /dev/null
  export SECURITY_DIR="reports/security"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "verdict.sh failed: $output"
  contains "$output" 'policy: clean' || fail "the merge did not read SECURITY_DIR: $output"
  [ -s "$GITHUB_WORKSPACE/reports/security/verdict.json" ] || fail "the merge did not write its verdict beside the SARIF it read"
}

# $0 is relative here, and the script moves into the consumer before running
# the merge: the merge's path has to be settled before that move.
@test "verdict.sh called by a relative path finds the merge" {
  GITHUB_WORKSPACE="$(consumer relative)"
  export GITHUB_WORKSPACE
  sarif "$GITHUB_WORKSPACE/.security/sbom.sarif" sbom < /dev/null
  run bash -c 'cd "$1" && bash scripts/security/verdict.sh' _ "$REPO_ROOT"
  [ "$status" -eq 0 ] || fail "verdict.sh failed: $output"
  contains "$output" 'sbom: clean' || fail "the merge did not run: $output"
}

@test "verdict.sh fails when node is not on the PATH" {
  GITHUB_WORKSPACE="$(consumer no-node)"
  export GITHUB_WORKSPACE
  run env PATH="$(path_without_node)" "$BASH" "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: node' || fail "the error does not name node: $output"
}

@test "verdict.sh refuses to report a clean run when there is no SARIF directory" {
  GITHUB_WORKSPACE="$(consumer no-directory)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "a missing .security/ produced a verdict: $output"
  contains "$output" '::error::no SARIF files in .security' || fail "the error does not say what was missing: $output"
  not_contains "$output" 'security: pass' || fail "the merge ran although nothing was reported: $output"
}

@test "verdict.sh refuses a SARIF directory that holds no SARIF" {
  GITHUB_WORKSPACE="$(consumer no-sarif)"
  export GITHUB_WORKSPACE
  mkdir -p "$GITHUB_WORKSPACE/.security"
  printf 'not a report' > "$GITHUB_WORKSPACE/.security/notes.txt"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "a directory without SARIF produced a verdict: $output"
  contains "$output" '::error::no SARIF files in .security' || fail "the error does not name the directory: $output"
  not_contains "$output" 'security: pass' || fail "the merge ran although nothing was reported: $output"
}

# The real merge always ends on its `security:` line; a merge that printed only
# workflow commands would leave grep -v keeping nothing, which under pipefail
# must not fail the step.
@test "verdict.sh still writes the summary block when the merge prints only annotations" {
  local script
  script="$(layout_with_merge <<'EOF'
console.log('::warning file=a,line=1::x');
EOF
)"
  GITHUB_WORKSPACE="$(consumer only-annotations)"
  export GITHUB_WORKSPACE
  sarif "$GITHUB_WORKSPACE/.security/code.sarif" code < /dev/null
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$script"
  [ "$status" -eq 0 ] || fail "grep keeping no line failed the step under pipefail: $status / $output"
  grep -q '^## Security' "$GITHUB_STEP_SUMMARY" || fail "the summary block is missing"
  [ -z "$(grep '^::' "$GITHUB_STEP_SUMMARY" || true)" ] \
    || fail "a workflow command leaked into the run summary: $(cat "$GITHUB_STEP_SUMMARY")"
}
