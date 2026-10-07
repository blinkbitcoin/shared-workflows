#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/e2e-env.sh: the one entry point every native and E2E script
# sources. It assembles the contract from shared-env.sh and the e2e-*.sh files
# (each tested in its own file, named after it) and makes the run's side
# effects in workflows_e2e_init. Covered here: every public function and
# variable is there after sourcing the entry alone; WORKFLOWS_OUT is created
# and WORKFLOWS_OUT and WORKFLOWS_RUN_START published once, within one process
# and across processes; the run-start stamp is made once, marked fresh only in
# the process that made it, and never touched again; and a stamp that cannot be
# written leaves the run unmarked rather than failing the caller.
#
# e2e-env.sh is a library (sourced, not executed), so each case sources it
# from a throwaway bash -c process rather than `run bash script.sh`.
load test_helper

setup() {
  GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
  export GITHUB_ENV
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export WORKFLOWS_OUT
}

# e2e_env COMMANDS - runs COMMANDS in a fresh bash that has sourced common.sh
# and the entry, under the options every caller sets.
e2e_env() {
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/e2e-env.sh"; eval "$2"' _ "$REPO_ROOT" "$1"
}

@test "the entry alone defines every function and variable of the contract" {
  e2e_env '
    for f in workflows_platform workflows_out_init workflows_e2e_init workflows_app_config workflows_app_id \
      workflows_scheme workflows_ios_scheme workflows_run_hook workflows_ios_unified_log_predicate \
      workflows_sim_udid workflows_driver_startup_timeout workflows_assert_suite_ran workflows_metro_background; do
      [ "$(type -t "$f")" = function ] || echo "missing function $f"
    done
    bash -c "for v in WORKFLOWS_OUT WORKFLOWS_LIB_DIR WORKFLOWS_RUN_START WORKFLOWS_RUN_START_FRESH WORKFLOWS_DEV_CLIENT \
      WORKFLOWS_IOS_CONFIGURATION WORKFLOWS_IOS_PRODUCTS_DIR WORKFLOWS_ANDROID_APK WORKFLOWS_MAESTRO_FLOWS \
      WORKFLOWS_SUITE_TIMEOUT_MINUTES WORKFLOWS_METRO_PORT WORKFLOWS_MOCK_API_PORT; do
      [ -n \"\${!v+set}\" ] || echo \"not exported: \$v\"
    done"
    echo done'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "done" ] || fail "the entry is missing part of the contract: $output"
}

@test "publishes WORKFLOWS_OUT and WORKFLOWS_RUN_START to GITHUB_ENV, and creates WORKFLOWS_OUT" {
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -d "$WORKFLOWS_OUT" ] || fail "WORKFLOWS_OUT was not created"
  grep -qxF "WORKFLOWS_OUT=$WORKFLOWS_OUT" "$GITHUB_ENV" || fail "WORKFLOWS_OUT not published: $(cat "$GITHUB_ENV")"
  grep -qxF "WORKFLOWS_RUN_START=$WORKFLOWS_OUT/run-start" "$GITHUB_ENV" || fail "WORKFLOWS_RUN_START not published: $(cat "$GITHUB_ENV")"
}

@test "sourcing twice in the same process appends each variable once" {
  run bash -c "
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
  "
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ] || fail "WORKFLOWS_OUT: $(cat "$GITHUB_ENV")"
  [ "$(grep -c '^WORKFLOWS_RUN_START=' "$GITHUB_ENV")" -eq 1 ] || fail "WORKFLOWS_RUN_START: $(cat "$GITHUB_ENV")"
}

@test "sourcing from separate processes sharing GITHUB_ENV appends each variable once" {
  # Each GitHub Actions step is its own process; the dedupe guard must be
  # file-based (grep $GITHUB_ENV itself), not a shell-variable flag that only
  # survives within one process.
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ] || fail "WORKFLOWS_OUT: $(cat "$GITHUB_ENV")"
  [ "$(grep -c '^WORKFLOWS_RUN_START=' "$GITHUB_ENV")" -eq 1 ] || fail "WORKFLOWS_RUN_START: $(cat "$GITHUB_ENV")"
}

@test "the run-start stamp is made by the first process, marked fresh only there, and never touched again" {
  e2e_env 'printf "fresh=[%s]\n" "$WORKFLOWS_RUN_START_FRESH"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "fresh=[1]" ] || fail "the first process did not mark the stamp fresh: $output"
  [ -f "$WORKFLOWS_OUT/run-start" ] || fail "no stamp at $WORKFLOWS_OUT/run-start"
  touch -t 200001010000 "$WORKFLOWS_OUT/run-start"
  e2e_env 'printf "fresh=[%s]\n" "$WORKFLOWS_RUN_START_FRESH"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "fresh=[]" ] || fail "a later process marked the stamp fresh: $output"
  [ -z "$(find "$WORKFLOWS_OUT/run-start" -newermt 2000-01-02)" ] || fail "a later process touched the stamp"
}

@test "a stamp that cannot be written leaves the run unmarked, and the caller carries on" {
  [ "$(id -u)" -ne 0 ] || skip "root writes into a read-only directory"
  mkdir -p "$WORKFLOWS_OUT"
  chmod a-w "$WORKFLOWS_OUT"
  e2e_env 'printf "fresh=[%s]\n" "$WORKFLOWS_RUN_START_FRESH"'
  chmod u+w "$WORKFLOWS_OUT"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  # The shell reports the refused write on stderr, as it always has.
  contains "$output" "fresh=[]" || fail "no marker printed: $output"
  not_contains "$output" "fresh=[1]" || fail "an unwritten stamp was marked fresh: $output"
  [ ! -e "$WORKFLOWS_OUT/run-start" ] || fail "a stamp appeared in a read-only directory"
}
