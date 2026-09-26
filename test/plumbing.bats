#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# Cases that hold several small scripts to each other. A case about one script
# belongs in that script's own test file (step-timeout.bats, run-hook.bats,
# e2e-env-publish.bats, release-env-publish.bats, check-versions.bats), not
# here.

load test_helper

setup() {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_ENV"
  export GITHUB_ENV
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
}

@test "a job that runs both env-publish scripts keeps one output directory" {
  # release-env.sh mirrors e2e-env.sh's WORKFLOWS_OUT on purpose: a job that
  # does both must stage everything in one directory, and publish it once.
  bash "$REPO_ROOT/scripts/e2e/env-publish.sh" 2>/dev/null
  bash "$REPO_ROOT/scripts/release/env-publish.sh" 2>/dev/null
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ] || fail "WORKFLOWS_OUT published more than once: $(cat "$GITHUB_ENV")"
  grep -qx "WORKFLOWS_OUT=$RUNNER_TEMP/workflows" "$GITHUB_ENV" || fail "the two scripts disagree on the output directory: $(cat "$GITHUB_ENV")"
  grep -qx "WORKFLOWS_RUN_START=$RUNNER_TEMP/workflows/run-start" "$GITHUB_ENV" || fail "the e2e stamp is missing: $(cat "$GITHUB_ENV")"
  grep -qx "WORKFLOWS_OTA_DIR=$RUNNER_TEMP/workflows/ota" "$GITHUB_ENV" || fail "the release directories are missing: $(cat "$GITHUB_ENV")"
}
