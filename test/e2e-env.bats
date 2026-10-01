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
# the workspace filename is what it returns. test-e2e.yml now skips Setup on a cache
# hit, so the scheme must resolve with no pnpm, no node_modules and no expo.
@test "the iOS scheme resolves from the workspace alone, with no expo config available" {
  root="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$root/ios/RNMobileTemplatedev.xcworkspace"
  # The resolver logs its reason on stderr; only stdout is the scheme. node
  # stays on PATH: the stack is asked of native-stack.mjs.
  run env -u EXPO_CONFIG_JSON GITHUB_WORKSPACE="$root" WORKING_DIRECTORY=. PATH="$(dirname "$(command -v node)"):/usr/bin:/bin" \
    WORKFLOWS_NATIVE_STACK_INPUT=expo \
    bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'; workflows_ios_scheme 2>/dev/null"
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
  run env GITHUB_WORKSPACE="$root" WORKING_DIRECTORY=. EXPO_CONFIG_JSON="$cfg" WORKFLOWS_NATIVE_STACK_INPUT=expo \
    bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'; workflows_ios_scheme"
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" "::warning::" || fail "no warning; output: $output"
  contains "$output" "FromWorkspace" || fail "output: $output"
}

# The platform used to be read inside a `case` word, where a failing `$(...)`
# never stops the shell: an unknown platform printed its error and the function
# still returned 0 with an empty application id.
@test "workflows_app_id with an unknown platform fails instead of answering an empty id" {
  run bash -c "set -euo pipefail
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    id=\"\$(workflows_app_id windows)\"
    echo \"reached with id='\$id'\""
  [ "$status" -ne 0 ] || fail "an unknown platform answered: $output"
  contains "$output" "platform must be ios or android (got 'windows')" || fail "output: $output"
  not_contains "$output" "reached with id" || fail "the caller carried on: $output"
}

@test "workflows_app_id prefers WORKFLOWS_APP_ID, and otherwise asks the Expo stack's configuration" {
  run bash -c "WORKFLOWS_APP_ID=com.example.override
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    workflows_app_id windows"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "com.example.override" || fail "the override was not used: $output"

  printf '{"ios":{"bundleIdentifier":"com.example.ios"},"android":{"package":"com.example.android"}}\n' \
    > "$BATS_TEST_TMPDIR/expo.json"
  local platform
  for platform in ios android; do
    run bash -c "export EXPO_CONFIG_JSON='$BATS_TEST_TMPDIR/expo.json' WORKFLOWS_NATIVE_STACK_INPUT=expo
      source '$REPO_ROOT/scripts/lib/common.sh'
      source '$REPO_ROOT/scripts/lib/e2e-env.sh'
      workflows_app_id $platform"
    [ "$status" -eq 0 ] || fail "$platform: status $status: $output"
    contains "$output" "com.example.$platform" || fail "$platform: $output"
  done
}

@test "read through \$(...), the iOS scheme stops on a working directory that does not exist" {
  run bash -c "set -euo pipefail
    export GITHUB_WORKSPACE='$BATS_TEST_TMPDIR' WORKING_DIRECTORY=missing
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    scheme=\"\$(workflows_ios_scheme)\"
    echo \"reached with scheme='\$scheme'\""
  [ "$status" -ne 0 ] || fail "the caller carried on: $output"
  not_contains "$output" "reached with" || fail "the caller carried on: $output"
  not_contains "$output" "no ios/*.xcworkspace in  -" || fail "it looked for a workspace under an empty root: $output"
}

# Each identifier is asked of the consumer's native stack. Against the bare
# fixture that is its committed projects: no expo, no pnpm, no node_modules.
# xcodebuild is a fake that fails, as on a runner without Pods, so the bundle
# identifier comes from the project file.
@test "against the bare fixture, every identifier comes from the committed native projects" {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 65\n' > "$bin/xcodebuild"
  chmod +x "$bin/xcodebuild"
  run env GITHUB_WORKSPACE="$FIXTURES/consumer-bare" WORKING_DIRECTORY=. PATH="$bin:$PATH" bash -c "
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    {
      printf 'ios=%s\n' \"\$(workflows_app_id ios)\"
      printf 'android=%s\n' \"\$(workflows_app_id android)\"
      printf 'scheme=[%s]\n' \"\$(workflows_scheme)\"
      printf 'xcode=%s\n' \"\$(workflows_ios_scheme)\"
    } 2>/dev/null"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "ios=com.example.bare
android=com.example.bare
scheme=[]
xcode=App" ] || fail "got: $output"
}

@test "against the Expo fixture, the identifiers come from the Expo configuration" {
  printf '{"name":"Fixture App","scheme":"fixture","ios":{"bundleIdentifier":"com.example.expo"},"android":{"package":"com.example.expo.android"}}\n' \
    > "$BATS_TEST_TMPDIR/expo.json"
  run env GITHUB_WORKSPACE="$FIXTURES/consumer-min" WORKING_DIRECTORY=. EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json" bash -c "
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    {
      printf 'ios=%s\n' \"\$(workflows_app_id ios)\"
      printf 'android=%s\n' \"\$(workflows_app_id android)\"
      printf 'scheme=%s\n' \"\$(workflows_scheme)\"
    } 2>/dev/null"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "ios=com.example.expo
android=com.example.expo.android
scheme=fixture" ] || fail "got: $output"
}

@test "workflows_metro_background starts the command in its own process group, with the log and PID" {
  run bash -c "set -euo pipefail
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-env.sh'
    WORKFLOWS_METRO_PORT=9999 workflows_metro_background bash -c 'printf \"CI=%s\\n\" \"\$CI\"'"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  pid="$(cat "$WORKFLOWS_OUT/metro.pid")"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "not a PID: $pid"
  contains "$output" "Metro starting (pid $pid, port 9999, log $WORKFLOWS_OUT/metro.log)" || fail "output: $output"
  contains "$output" "stop it with: kill -TERM -$pid" || fail "output: $output"
  for i in $(seq 1 50); do
    [ -s "$WORKFLOWS_OUT/metro.log" ] && break
    sleep 0.2
  done
  [ "$(cat "$WORKFLOWS_OUT/metro.log")" = "CI=1" ] || fail "the command did not run with CI=1: $(cat "$WORKFLOWS_OUT/metro.log")"
}
