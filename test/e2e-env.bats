#!/usr/bin/env bats
load test_helper

# e2e-env.sh is a library (sourced, not executed), so each case sources it
# from a throwaway bash -c process rather than `run bash script.sh`.
setup() {
  GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
  export GITHUB_ENV
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export WORKFLOWS_OUT
}

@test "publishes WORKFLOWS_OUT and WORKFLOWS_RUN_START to GITHUB_ENV" {
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'"
  [ "$status" -eq 0 ]
  grep -qxF "WORKFLOWS_OUT=$WORKFLOWS_OUT" "$GITHUB_ENV"
  grep -qxF "WORKFLOWS_RUN_START=$WORKFLOWS_OUT/run-start" "$GITHUB_ENV"
}

@test "sourcing twice in the same process appends each variable once" {
  run bash -c "
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
  "
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ]
  [ "$(grep -c '^WORKFLOWS_RUN_START=' "$GITHUB_ENV")" -eq 1 ]
}

@test "sourcing from separate processes sharing GITHUB_ENV appends each variable once" {
  # Each GitHub Actions step is its own process; the dedupe guard must be
  # file-based (grep $GITHUB_ENV itself), not a shell-variable flag that only
  # survives within one process.
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'"
  [ "$status" -eq 0 ]
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ]
  [ "$(grep -c '^WORKFLOWS_RUN_START=' "$GITHUB_ENV")" -eq 1 ]
}

# The warm iOS build spent ~80s installing a dependency tree so that
# workflows_ios_scheme could ask the Expo config for a name it then discarded -
# the workspace filename is what it returns. check-e2e.yml now skips Setup on a cache
# hit, so the scheme must resolve with no pnpm, no node_modules and no expo.
@test "the iOS scheme resolves from the workspace alone, with no expo config available" {
  root="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$root/ios/RNMobileTemplatedev.xcworkspace"
  run env -u EXPO_CONFIG_JSON GITHUB_WORKSPACE="$root" WORKING_DIRECTORY=. PATH=/usr/bin:/bin \
    bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'; workflows_ios_scheme"
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  # bash 3.2 (macOS /bin/bash, which bats runs under) has no negative array
  # subscripts, so compare $output rather than ${lines[-1]}.
  [ "$output" = "RNMobileTemplatedev" ] || fail "got '$output'"
}

# ...and the cross-check still fires when the config IS there and disagrees:
# dropping it silently would hide a real prebuild/config mismatch.
@test "a disagreeing expo config still warns, and the workspace name still wins" {
  root="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$root/ios/FromWorkspace.xcworkspace"
  cfg="$BATS_TEST_TMPDIR/expo.json"
  printf '{"name":"FromConfig"}\n' > "$cfg"
  run env GITHUB_WORKSPACE="$root" WORKING_DIRECTORY=. EXPO_CONFIG_JSON="$cfg" \
    bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'; workflows_ios_scheme"
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "::warning::" || fail "no warning; output: $output"
  contains "$output" "FromWorkspace" || fail "output: $output"
}
