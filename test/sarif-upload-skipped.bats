#!/usr/bin/env bats
# scripts/security/sarif-upload-skipped.sh - the warning check-security.yml
# prints when the findings cannot be uploaded to code scanning. Covers every
# way out of it: the warning with a run summary, the same notice on stdout
# without one, and the refusal to run with no reason or an empty one.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

@test "sarif-upload-skipped.sh warns in the log and in the summary, with the reason" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh" "this run is a pull request from a fork"
  [ "$status" -eq 0 ] || fail "$output"
  contains "$output" '::warning::' || fail "a missing upload passed without an annotation: $output"
  contains "$output" 'pull request from a fork' || fail "the reason is missing: $output"
  grep -q 'not.*uploaded to code scanning' "$BATS_TEST_TMPDIR/summary.md" \
    || fail "the run summary does not say the findings never reached code scanning"
  grep -q 'still applied the threshold' "$BATS_TEST_TMPDIR/summary.md" \
    || fail "the run summary does not say the gate still ran"
}

@test "sarif-upload-skipped.sh refuses to run without a reason" {
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh"
  [ "$status" -ne 0 ] || fail "a reasonless notice is exactly the silence this step exists to prevent: $output"
}

@test "sarif-upload-skipped.sh refuses an empty reason, with its usage" {
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh" ""
  [ "$status" -ne 0 ] || fail "an empty reason passed: $output"
  contains "$output" 'usage: sarif-upload-skipped.sh REASON' || fail "the error does not show the usage: $output"
  not_contains "$output" '::warning::' || fail "a warning with no reason was printed: $output"
}

@test "sarif-upload-skipped.sh writes the summary notice to stdout when there is no run summary" {
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh" "the upload step was switched off"
  [ "$status" -eq 0 ] || fail "$output"
  contains "$output" '::warning::Security findings were not uploaded to code scanning: the upload step was switched off' \
    || fail "the annotation is missing or lost its reason: $output"
  contains "$output" '> Findings were **not** uploaded to code scanning: the upload step was switched off.' \
    || fail "without a run summary the notice did not go to stdout: $output"
  contains "$output" 'still applied the threshold' || fail "the notice does not say the gate still ran: $output"
}
