#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/ios-build.sh: an unsigned simulator build of the workspace's
# scheme, for a generic destination, piped through a formatter when there is
# one. xcodebuild, sudo and the formatters are fakes that record their calls;
# the fake xcodebuild lays down the .app a real build would.
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
  root="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  cat > "$bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf 'xcodebuild %s\n' "$*" >> "$CALLS"
echo "raw build log"
[ "${XCODEBUILD_STATUS:-0}" -eq 0 ] || exit "$XCODEBUILD_STATUS"
config=""
while [ "$#" -gt 0 ]; do [ "$1" = -configuration ] && config="$2"; shift; done
[ -n "${XCODEBUILD_NO_APP:-}" ] || mkdir -p "ios/build/Build/Products/$config-iphonesimulator/Demo.app"
STUB
  cat > "$bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$CALLS"
STUB
  chmod +x "$bin/xcodebuild" "$bin/sudo"
  # node for the stack resolver (packages/app-tooling/lib/native-stack.mjs),
  # which a runner always has; nothing else from this machine.
  export PATH="$bin:$(dirname "$(command -v node)"):/usr/bin:/bin"
}

formatter() {
  cat > "$bin/$1" <<STUB
#!/usr/bin/env bash
printf '$1\n' >> "\$CALLS"
sed 's/^/$1: /'
STUB
  chmod +x "$bin/$1"
}

build() { run bash "$REPO_ROOT/scripts/native/ios-build.sh"; }

@test "builds the workspace's scheme, Debug, unsigned, for a generic simulator, and publishes the .app" {
  build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(head -1 "$CALLS")" = "xcodebuild -workspace ios/Demo.xcworkspace -scheme Demo -configuration Debug -sdk iphonesimulator -destination generic/platform=iOS Simulator -derivedDataPath ios/build CODE_SIGNING_ALLOWED=NO build" ] \
    || fail "calls: $(cat "$CALLS")"
  contains "$output" "Xcode scheme: Demo" || fail "output: $output"
  contains "$(cat "$GITHUB_OUTPUT")" "app_path=$root/ios/build/Build/Products/Debug-iphonesimulator/Demo.app" \
    || fail "output: $(cat "$GITHUB_OUTPUT")"
}

@test "WORKFLOWS_IOS_CONFIGURATION=Release builds and publishes the Release products" {
  WORKFLOWS_IOS_CONFIGURATION=Release build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$CALLS")" "-configuration Release" || fail "calls: $(cat "$CALLS")"
  contains "$(cat "$GITHUB_OUTPUT")" "Release-iphonesimulator/Demo.app" || fail "output: $(cat "$GITHUB_OUTPUT")"
}

@test "without a formatter the raw log is shown" {
  build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "raw build log" || fail "output: $output"
}

@test "xcbeautify formats the log when present, ahead of xcpretty" {
  formatter xcbeautify
  formatter xcpretty
  build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "xcbeautify: raw build log" || fail "output: $output"
  not_contains "$(cat "$CALLS")" "xcpretty" || fail "calls: $(cat "$CALLS")"
}

@test "xcpretty formats the log when xcbeautify is missing" {
  formatter xcpretty
  build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "xcpretty: raw build log" || fail "output: $output"
}

@test "a failing build fails with xcodebuild's status, not the formatter's" {
  formatter xcbeautify
  XCODEBUILD_STATUS=65 build
  [ "$status" -ne 0 ] || fail "passed a failed build: $output"
  contains "$output" "xcodebuild failed with status 65" || fail "output: $output"
}

@test "WORKFLOWS_XCODE selects that Xcode first" {
  WORKFLOWS_XCODE=26.1 build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(head -1 "$CALLS")" = "sudo xcode-select -s /Applications/Xcode_26.1.app" ] || fail "calls: $(cat "$CALLS")"
  contains "$output" "selecting Xcode 26.1" || fail "output: $output"
}

@test "a build that succeeds without the .app is a failure that names it" {
  XCODEBUILD_NO_APP=1 build
  [ "$status" -ne 0 ] || fail "passed with no .app: $output"
  contains "$output" "build succeeded but ios/build/Build/Products/Debug-iphonesimulator/Demo.app is missing" || fail "output: $output"
}

@test "without a workspace it names the steps that make one, and builds nothing" {
  rmdir "$GITHUB_WORKSPACE/ios/Demo.xcworkspace"
  build
  [ "$status" -ne 0 ] || fail "built without a workspace: $output"
  contains "$output" "run prebuild.sh ios and pods.sh first" || fail "output: $output"
  not_contains "$(cat "$CALLS")" "xcodebuild" || fail "calls: $(cat "$CALLS")"
}

@test "no xcodebuild on PATH is named" {
  rm "$bin/xcodebuild"
  # macOS has an xcodebuild shim in /usr/bin, so offer everything there but it.
  usr="$BATS_TEST_TMPDIR/usr-bin"
  mkdir -p "$usr"
  for tool in /usr/bin/*; do
    [ "${tool##*/}" = xcodebuild ] || ln -s "$tool" "$usr/"
  done
  PATH="$bin:$usr:/bin" run bash "$REPO_ROOT/scripts/native/ios-build.sh"
  [ "$status" -ne 0 ] || fail "ran without xcodebuild: $output"
  contains "$output" "missing command: xcodebuild" || fail "output: $output"
}
