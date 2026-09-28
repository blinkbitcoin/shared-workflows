#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

SCRIPT="$REPO_ROOT/scripts/release/release-pr-read.sh"

setup() {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : > "$GITHUB_OUTPUT"
}

@test "the PR's number and branch become step outputs" {
  PR_JSON='{"number":42,"headBranchName":"release-please--branches--main","title":"chore(main): release 1.2.3"}' \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'number=42' "$GITHUB_OUTPUT" || fail "no number output: $(cat "$GITHUB_OUTPUT")"
  grep -qx 'branch=release-please--branches--main' "$GITHUB_OUTPUT" || fail "no branch output: $(cat "$GITHUB_OUTPUT")"
  contains "$output" "release PR #42 on release-please--branches--main" || fail "output: $output"
}

@test "an empty or unset pr output is an error, not a PR with no number" {
  PR_JSON='' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "accepted an empty pr output: $output"
  contains "$output" "PR_JSON is empty" || fail "output: $output"
  unset PR_JSON
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "accepted an unset pr output: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "wrote outputs anyway: $(cat "$GITHUB_OUTPUT")"
}

@test "a pr output that is not a JSON object is an error" {
  for bad in 'not json' '[{"number":1,"headBranchName":"b"}]'; do
    PR_JSON="$bad" run bash "$SCRIPT"
    [ "$status" -ne 0 ] || fail "accepted '$bad': $output"
    contains "$output" "PR_JSON is not a JSON object" || fail "output for '$bad': $output"
  done
}

@test "a PR with no number or no branch is an error naming both fields" {
  for bad in '{"headBranchName":"b"}' '{"number":42}'; do
    PR_JSON="$bad" run bash "$SCRIPT"
    [ "$status" -ne 0 ] || fail "accepted '$bad': $output"
    contains "$output" "lacks number or headBranchName: $bad" || fail "output for '$bad': $output"
  done
  [ ! -s "$GITHUB_OUTPUT" ] || fail "wrote outputs for an incomplete PR: $(cat "$GITHUB_OUTPUT")"
}
