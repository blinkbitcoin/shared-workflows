#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/ios-pack.sh: tar the built simulator .app so the upload keeps
# its symlinks and executable bits, and publish its path as the app_tar output.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  # The Expo stack: these cases read the Expo configuration's identifiers.
  export WORKFLOWS_NATIVE_STACK_INPUT=expo
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/none.json"
  : > "$GITHUB_OUTPUT"
  mkdir -p "$GITHUB_WORKSPACE/ios/Demo.xcworkspace"
}

built_app() {
  local app="$GITHUB_WORKSPACE/ios/build/Build/Products/${1:-Debug}-iphonesimulator/Demo.app"
  mkdir -p "$app"
  printf 'binary\n' > "$app/Demo"
  chmod +x "$app/Demo"
}

@test "packs the scheme's .app, keeping the executable bit, and publishes the tar's path" {
  built_app
  run bash "$REPO_ROOT/scripts/native/ios-pack.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  tar_path="$WORKFLOWS_OUT/Demo.app.tar"
  [ -f "$tar_path" ] || fail "no tar at $tar_path"
  contains "$(cat "$GITHUB_OUTPUT")" "app_tar=$tar_path" || fail "output: $(cat "$GITHUB_OUTPUT")"
  listing="$(tar -tvf "$tar_path")"
  contains "$listing" "Demo.app/Demo" || fail "listing: $listing"
  [[ "$(tar -tvf "$tar_path" | grep 'Demo.app/Demo')" == -rwx* ]] || fail "lost the executable bit: $listing"
}

@test "packs the Release products when the configuration is Release" {
  built_app Release
  WORKFLOWS_IOS_CONFIGURATION=Release run bash "$REPO_ROOT/scripts/native/ios-pack.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
}

@test "without a built .app it names the step that builds one" {
  run bash "$REPO_ROOT/scripts/native/ios-pack.sh"
  [ "$status" -ne 0 ] || fail "packed nothing: $output"
  contains "$output" "Demo.app - run ios-build.sh first" || fail "output: $output"
}

@test "without a workspace it names the steps that make one" {
  rmdir "$GITHUB_WORKSPACE/ios/Demo.xcworkspace"
  run bash "$REPO_ROOT/scripts/native/ios-pack.sh"
  [ "$status" -ne 0 ] || fail "ran without a workspace: $output"
  contains "$output" "run prebuild.sh ios and pods.sh first" || fail "output: $output"
}
