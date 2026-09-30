#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

SCRIPT="$REPO_ROOT/scripts/release/release-summary.sh"

@test "the released paths go to the job summary and the log" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  PATHS_RELEASED='[".","packages/app-tooling"]' run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qxF 'paths released: [".","packages/app-tooling"]' "$GITHUB_STEP_SUMMARY" \
    || fail "summary: $(cat "$GITHUB_STEP_SUMMARY")"
  contains "$output" 'paths released: [".","packages/app-tooling"]' || fail "output: $output"
}

@test "a push that released nothing says none" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  PATHS_RELEASED='' run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qxF 'paths released: none' "$GITHUB_STEP_SUMMARY" || fail "summary: $(cat "$GITHUB_STEP_SUMMARY")"
}

@test "with no job summary it still logs, and writes no file" {
  unset GITHUB_STEP_SUMMARY
  PATHS_RELEASED='["."]' run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" 'paths released: ["."]' || fail "output: $output"
}
