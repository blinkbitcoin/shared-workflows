#!/usr/bin/env bats
# The seam between the bridges check-security.yml runs. Each bridge has its own
# test file, named after it (settings.bats, run-job.bats, verdict.bats,
# sarif-upload-skipped.bats, binaries-fetch.bats), which covers every way out of
# that one script. What stays here is what no single script's file can show:
# that the bridges agree with each other - that the SARIF run-job.sh insists on
# is the SARIF verdict.sh merges. Both run for real, with this repository's own
# policy runner and merge, against a throwaway consumer: a clean run, a run
# with findings, a switched-off job, and a SARIF directory SECURITY_DIR moves.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  # The runner and the merge read SECURITY_* and find the consumer through
  # GITHUB_WORKSPACE and WORKING_DIRECTORY; the merge prints annotations only
  # under GITHUB_ACTIONS. A value leaking in from the caller's shell would
  # decide the outcome.
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY GITHUB_ACTIONS
  local name
  for name in $(compgen -e); do
    case "$name" in SECURITY_*) unset "$name" ;; esac
  done
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
}

# A consumer checkout named $1. With `compliant` as $2 its pnpm-workspace.yaml
# satisfies the policy runner; without, the runner finds all three settings
# missing. Prints its path.
consumer() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  if [ "${2:-}" = compliant ]; then
    printf 'minimumReleaseAge: 1440\nstrictDepBuilds: true\ntrustPolicy: no-downgrade\n' > "$dir/pnpm-workspace.yaml"
  fi
  printf '%s' "$dir"
}

@test "the SARIF run-job.sh insists on is the SARIF verdict.sh merges" {
  GITHUB_WORKSPACE="$(consumer clean compliant)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "verdict.sh failed on what run-job.sh accepted: $output"
  contains "$output" 'policy: clean' || fail "the merge did not see the runner's SARIF: $output"
  contains "$output" 'security: pass' || fail "a clean runner did not read as a pass: $output"
}

@test "a finding the runner reports is the finding the verdict fails on" {
  GITHUB_WORKSPACE="$(consumer findings)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 0 ] || fail "a runner with findings failed its own job: $output"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "the verdict did not fail on the runner's findings: $status / $output"
  contains "$output" 'policy: 3 finding(s), highest high' || fail "the merge did not read the runner's findings: $output"
  contains "$output" 'pnpm/minimum-release-age' || fail "the merge dropped the runner's rule: $output"
}

# A switched-off job still writes a SARIF, so run-job.sh accepts it and the
# verdict says "skipped" rather than reading the silence as clean.
@test "a job switched off in security-settings.json reaches the verdict as skipped, never as clean" {
  GITHUB_WORKSPACE="$(consumer off compliant)"
  export GITHUB_WORKSPACE
  printf '{ "jobs": { "policy": { "enabled": false } } }\n' > "$GITHUB_WORKSPACE/security-settings.json"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 0 ] || fail "run-job.sh refused a skipped SARIF: $output"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "a skipped job failed the verdict: $status / $output"
  contains "$output" 'policy: skipped: disabled' || fail "the merge did not read the skip: $output"
  contains "$output" 'security: skipped' || fail "a skipped run read as something else: $output"
  not_contains "$output" 'security: pass' || fail "a skipped run read as a pass: $output"
}

@test "run-job.sh and verdict.sh agree on the directory SECURITY_DIR names" {
  GITHUB_WORKSPACE="$(consumer moved compliant)"
  export GITHUB_WORKSPACE
  export SECURITY_DIR="reports/security"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "verdict.sh failed on what run-job.sh accepted: $output"
  contains "$output" 'policy: clean' || fail "the merge did not see the runner's SARIF: $output"
  [ ! -e "$GITHUB_WORKSPACE/.security" ] || fail "one of the bridges used the default directory although SECURITY_DIR was set"
}
