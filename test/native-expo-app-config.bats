#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/expo/app-config.sh, the Expo stack's identifiers: each key
# mapped onto the resolved Expo config (EXPO_CONFIG_JSON feeds a fixture, the
# seam scripts/lib/expo-config.sh offers), and the Xcode scheme taken from the
# workspace prebuild wrote, cross-checked against the config's name. Covered:
# every key, the explicit inputs winning without asking the config, a key the
# config lacks, an unknown key, the scheme with and
# without the config at hand, a disagreement, no workspace, and a working
# directory that does not exist.
load test_helper

setup() {
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP"
  export GITHUB_WORKSPACE="$APP" WORKING_DIRECTORY=.
  unset IOS_BUNDLE_ID ANDROID_PACKAGE IOS_SCHEME
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json"
  printf '{"name":"My App!","scheme":"myapp","ios":{"bundleIdentifier":"com.example.ios"},"android":{"package":"com.example.android"}}\n' \
    > "$EXPO_CONFIG_JSON"
}

config() { run bash "$REPO_ROOT/scripts/native/expo/app-config.sh" "$@"; }

@test "each identifier comes from its key in the Expo config" {
  config ios-bundle-id
  [ "$output" = com.example.ios ] || fail "ios-bundle-id: $status $output"
  config android-package
  [ "$output" = com.example.android ] || fail "android-package: $status $output"
  config scheme
  [ "$output" = myapp ] || fail "scheme: $status $output"
}

@test "the explicit inputs win, and the Expo config is not asked" {
  # A config that cannot be read proves it is never asked.
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/absent.json"
  IOS_BUNDLE_ID=com.example.input config ios-bundle-id
  [ "$status" -eq 0 ] && [ "$output" = com.example.input ] || fail "ios-bundle-id: $status $output"
  ANDROID_PACKAGE=com.example.input.dev config android-package
  [ "$status" -eq 0 ] && [ "$output" = com.example.input.dev ] || fail "android-package: $status $output"
  # No workspace either: the input answers before one is looked for.
  IOS_SCHEME=Input config ios-scheme
  [ "$status" -eq 0 ] && [ "$output" = Input ] || fail "ios-scheme: $status $output"
}

@test "a key the config lacks fails, naming it" {
  printf '{"name":"App"}\n' > "$EXPO_CONFIG_JSON"
  config scheme
  [ "$status" -ne 0 ] || fail "answered a missing key: $output"
  contains "$output" "expo config key not found: scheme" || fail "output: $output"
}

@test "the Xcode scheme is the workspace's name, and an agreeing config says nothing" {
  mkdir -p "$APP/ios/MyApp.xcworkspace"
  config ios-scheme
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = MyApp ] || fail "got: $output"
}

@test "a disagreeing config warns, and the workspace still wins" {
  mkdir -p "$APP/ios/Generated.xcworkspace"
  config ios-scheme
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning::expo-config scheme-name (MyApp) disagrees with the generated workspace (Generated)" || fail "output: $output"
  [ "$(printf '%s\n' "$output" | tail -1)" = Generated ] || fail "output: $output"
}

@test "with no config at hand the scheme still resolves, without a cross-check" {
  mkdir -p "$APP/ios/Generated.xcworkspace"
  EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/absent.json" config ios-scheme
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = Generated ] || fail "got: $output"
}

@test "no workspace names the steps that make one" {
  config ios-scheme
  [ "$status" -ne 0 ] || fail "answered without a workspace: $output"
  contains "$output" "no ios/*.xcworkspace in $(cd "$APP" && pwd -P) - run prebuild.sh ios and pods.sh first" || fail "output: $output"
}

@test "a working directory that does not exist fails for the scheme" {
  WORKING_DIRECTORY=missing config ios-scheme
  [ "$status" -ne 0 ] || fail "answered: $output"
  contains "$output" "the consumer's working directory does not exist" || fail "output: $output"
}

@test "an unknown key fails naming the four" {
  config bundle
  [ "$status" -ne 0 ] || fail "answered an unknown key: $output"
  contains "$output" "unknown app-config key 'bundle' (one of: ios-bundle-id, android-package, scheme, ios-scheme)" || fail "output: $output"
}
