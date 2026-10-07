#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/e2e-app.sh: the app under test, in the E2E env contract. Covered
# here: the build defaults (Debug, and the products directory following a
# Release configuration), that sourcing it creates nothing, every identifier
# from both native stacks (workflows_app_id with an override, per platform and
# with an unknown platform; workflows_scheme; workflows_ios_scheme from the
# workspace alone, against a disagreeing configuration and with a working
# directory that does not exist), and workflows_run_hook (no hook, a hook that
# runs from the consumer root, a hook file that does not exist).
load test_helper

setup() {
  GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
  export GITHUB_ENV
  WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export WORKFLOWS_OUT
  unset WORKFLOWS_APP_ID WORKFLOWS_DEV_CLIENT WORKFLOWS_IOS_CONFIGURATION WORKFLOWS_PLATFORM
}

# app_env COMMANDS - runs COMMANDS in a fresh bash that has sourced common.sh
# and this library, under the options every caller sets.
app_env() {
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/e2e-app.sh"; eval "$2"' _ "$REPO_ROOT" "$1"
}

# --- the build defaults --------------------------------------------------------

@test "the app builds Debug with the dev client by default, and the paths reach child processes" {
  app_env 'bash -c "printf \"%s\\n\" \"\$WORKFLOWS_DEV_CLIENT\" \"\$WORKFLOWS_IOS_CONFIGURATION\" \"\$WORKFLOWS_IOS_PRODUCTS_DIR\" \"\$WORKFLOWS_ANDROID_APK\""'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "true
Debug
ios/build/Build/Products/Debug-iphonesimulator
android/app/build/outputs/apk/debug/app-debug.apk" ] || fail "got: $output"
}

@test "a Release configuration moves the iOS products directory with it" {
  WORKFLOWS_IOS_CONFIGURATION=Release WORKFLOWS_DEV_CLIENT=false app_env 'printf "%s|%s\n" "$WORKFLOWS_DEV_CLIENT" "$WORKFLOWS_IOS_PRODUCTS_DIR"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "false|ios/build/Build/Products/Release-iphonesimulator" ] || fail "got: $output"
}

@test "sourcing it creates nothing and publishes nothing" {
  app_env 'true'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -e "$WORKFLOWS_OUT" ] || fail "sourcing the library created $WORKFLOWS_OUT"
  [ ! -s "$GITHUB_ENV" ] || fail "sourcing the library published: $(cat "$GITHUB_ENV")"
}

# --- the identifiers -----------------------------------------------------------

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
    bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-app.sh'; workflows_ios_scheme 2>/dev/null"
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
    bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-app.sh'; workflows_ios_scheme"
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
    source '$REPO_ROOT/scripts/lib/e2e-app.sh'
    id=\"\$(workflows_app_id windows)\"
    echo \"reached with id='\$id'\""
  [ "$status" -ne 0 ] || fail "an unknown platform answered: $output"
  contains "$output" "platform must be ios or android (got 'windows')" || fail "output: $output"
  not_contains "$output" "reached with id" || fail "the caller carried on: $output"
}

@test "workflows_app_id prefers WORKFLOWS_APP_ID, and otherwise asks the Expo stack's configuration" {
  run bash -c "WORKFLOWS_APP_ID=com.example.override
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-app.sh'
    workflows_app_id windows"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "com.example.override" || fail "the override was not used: $output"

  printf '{"ios":{"bundleIdentifier":"com.example.ios"},"android":{"package":"com.example.android"}}\n' \
    > "$BATS_TEST_TMPDIR/expo.json"
  local platform
  for platform in ios android; do
    run bash -c "export EXPO_CONFIG_JSON='$BATS_TEST_TMPDIR/expo.json' WORKFLOWS_NATIVE_STACK_INPUT=expo
      source '$REPO_ROOT/scripts/lib/common.sh'
      source '$REPO_ROOT/scripts/lib/e2e-app.sh'
      workflows_app_id $platform"
    [ "$status" -eq 0 ] || fail "$platform: status $status: $output"
    contains "$output" "com.example.$platform" || fail "$platform: $output"
  done
}

@test "read through \$(...), the iOS scheme stops on a working directory that does not exist" {
  run bash -c "set -euo pipefail
    export GITHUB_WORKSPACE='$BATS_TEST_TMPDIR' WORKING_DIRECTORY=missing
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/e2e-app.sh'
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
    source '$REPO_ROOT/scripts/lib/e2e-app.sh'
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
    source '$REPO_ROOT/scripts/lib/e2e-app.sh'
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

# --- workflows_run_hook ----------------------------------------------------------

@test "workflows_run_hook does nothing when the variable names no hook" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/missing" WORKING_DIRECTORY=.
  HOOK="" app_env 'workflows_run_hook HOOK; echo "returned $?"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "returned 0" ] || fail "an empty hook did something: $output"
  app_env 'unset HOOK; workflows_run_hook HOOK; echo "returned $?"'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "returned 0" ] || fail "an unset hook did something: $output"
}

@test "workflows_run_hook runs the hook from the consumer root, and logs it" {
  mkdir -p "$BATS_TEST_TMPDIR/consumer/e2e"
  printf 'printf "hook ran in %%s\\n" "$PWD"\n' > "$BATS_TEST_TMPDIR/consumer/e2e/up.sh"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=consumer
  HOOK=e2e/up.sh app_env 'workflows_run_hook HOOK'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "running HOOK: e2e/up.sh" || fail "the hook was not logged: $output"
  contains "$output" "hook ran in $(cd "$BATS_TEST_TMPDIR/consumer" && pwd -P)" || fail "the hook did not run from the root: $output"
}

@test "workflows_run_hook refuses a hook file that does not exist, naming the variable and the path" {
  mkdir -p "$BATS_TEST_TMPDIR/consumer"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=consumer
  HOOK=e2e/missing.sh app_env 'workflows_run_hook HOOK; echo reached'
  [ "$status" -ne 0 ] || fail "a missing hook was skipped: $output"
  contains "$output" "HOOK points at a missing file: $(cd "$BATS_TEST_TMPDIR/consumer" && pwd -P)/e2e/missing.sh" || fail "output: $output"
  not_contains "$output" "reached" || fail "the caller carried on: $output"
}
