#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/native-stack.sh: the one place the workflows' scripts ask which
# native stack the consumer is, and the dispatch to that stack's entry point.
# The rule itself is packages/app-tooling/lib/native-stack.mjs (its own cases
# are in packages/app-tooling/native-stack.test.mjs); these cases pin that the
# wrapper asks it, with the input and the consumer root, and what it does with
# the answer. Covered: each rule's answer reaching the caller, an invalid
# input failing with the fix, no node, a resolver missing from the checkout and
# the package layout that keeps it beside this file, a working directory that
# does not exist, the three ways to use it (print, run an entry point, source),
# an unknown entry point, and both fixture consumers.
load test_helper

setup() {
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP"
  export GITHUB_WORKSPACE="$APP" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  unset WORKFLOWS_NATIVE_STACK_INPUT WORKFLOWS_NATIVE_STACK
}

stack() { run bash "$REPO_ROOT/scripts/lib/native-stack.sh" "$@"; }

last_line() { printf '%s\n' "$output" | tail -1; }

package_json() { printf '%s\n' "$1" > "$APP/package.json"; }

# A git repository at the app root with ios/ tracked.
tracked_ios() {
  git -C "$APP" init -q
  mkdir -p "$APP/ios/App.xcodeproj"
  printf 'project\n' > "$APP/ios/App.xcodeproj/project.pbxproj"
  git -C "$APP" add ios
}

@test "rule 1: the input decides, and the module says so" {
  package_json '{"dependencies":{"expo":"57.0.0"}}'
  for value in expo bare; do
    WORKFLOWS_NATIVE_STACK_INPUT="$value" stack
    [ "$status" -eq 0 ] || fail "$value: exited $status: $output"
    contains "$output" "native stack: $value (the native-stack input)" || fail "$value: $output"
    [ "$(last_line)" = "$value" ] || fail "$value: printed $output"
  done
}

@test "rule 2: expo as a dependency and no tracked ios/ is the Expo stack" {
  package_json '{"devDependencies":{"expo":"57.0.0"}}'
  stack
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "native stack: expo (expo is a dependency and git tracks no ios/)" || fail "output: $output"
  [ "$(last_line)" = expo ] || fail "printed $output"
}

@test "rule 3: a tracked ios/, or no expo dependency, is the bare stack" {
  package_json '{"dependencies":{"expo":"57.0.0"}}'
  tracked_ios
  stack
  contains "$output" "native stack: bare (git tracks ios/, so the native projects are committed source)" || fail "output: $output"
  [ "$(last_line)" = bare ] || fail "printed $output"
  package_json '{"dependencies":{"react-native":"0.85.2"}}'
  stack
  contains "$output" "native stack: bare (expo is not a dependency in package.json)" || fail "output: $output"
  [ "$(last_line)" = bare ] || fail "printed $output"
}

@test "an invalid input fails with the module's reason and the fix" {
  WORKFLOWS_NATIVE_STACK_INPUT=Expo stack
  [ "$status" -eq 1 ] || fail "accepted Expo: $output"
  contains "$output" 'native-stack is "Expo": expected expo, bare or empty' || fail "the module's reason is missing: $output"
  contains "$output" "could not resolve the native stack of $(cd "$APP" && pwd -P)" || fail "output: $output"
  contains "$output" "Fix: pass native-stack: expo or native-stack: bare" || fail "no fix: $output"
  contains "$output" "consumer-guide.md#expo-or-bare" || fail "no contract anchor: $output"
}

@test "without node it names the missing command" {
  dir="$BATS_TEST_TMPDIR/no-node"
  mkdir -p "$dir"
  for tool in bash dirname; do ln -sf "$(command -v "$tool")" "$dir/$tool"; done
  WORKFLOWS_NATIVE_STACK_INPUT=bare PATH="$dir" stack
  [ "$status" -eq 1 ] || fail "resolved without node: $output"
  contains "$output" "missing command: node" || fail "output: $output"
}

@test "the resolver beside it, as in the app-tooling package, is the one it runs" {
  lib="$BATS_TEST_TMPDIR/package/lib"
  mkdir -p "$lib"
  cp "$REPO_ROOT/scripts/lib/native-stack.sh" "$REPO_ROOT/scripts/lib/common.sh" "$lib/"
  cat > "$lib/native-stack.mjs" <<'JS'
process.stderr.write(`native stack: bare (the copy beside it, ${process.argv.slice(2).join(' ')})\n`);
process.stdout.write('bare\n');
JS
  run bash "$lib/native-stack.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "(the copy beside it, --root $(cd "$APP" && pwd -P) --input )" || fail "the package's copy was not run: $output"
}

@test "a checkout without the resolver says it is incomplete" {
  lib="$BATS_TEST_TMPDIR/alone/lib"
  mkdir -p "$lib"
  cp "$REPO_ROOT/scripts/lib/native-stack.sh" "$REPO_ROOT/scripts/lib/common.sh" "$lib/"
  run bash "$lib/native-stack.sh"
  [ "$status" -eq 1 ] || fail "resolved without a resolver: $output"
  contains "$output" "no native-stack.mjs beside $lib" || fail "output: $output"
}

@test "a working directory that does not exist fails before the module runs" {
  WORKING_DIRECTORY=missing stack
  [ "$status" -eq 1 ] || fail "resolved a missing directory: $output"
  contains "$output" "the consumer's working directory does not exist" || fail "output: $output"
  not_contains "$output" "native stack:" || fail "the module ran anyway: $output"
}

@test "with an entry point it runs that stack's script, arguments passed on" {
  mkdir -p "$APP/ios/Fixture.xcworkspace"
  WORKFLOWS_NATIVE_STACK_INPUT=bare stack app-config ios-scheme
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(last_line)" = Fixture ] || fail "the bare app-config did not run: $output"
  printf '{"ios":{"bundleIdentifier":"com.example.from.expo"}}\n' > "$BATS_TEST_TMPDIR/expo.json"
  EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json" WORKFLOWS_NATIVE_STACK_INPUT=expo stack app-config ios-bundle-id
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(last_line)" = com.example.from.expo ] || fail "the expo app-config did not run: $output"
}

@test "an unknown entry point fails naming the four" {
  WORKFLOWS_NATIVE_STACK_INPUT=bare stack build
  [ "$status" -eq 1 ] || fail "ran an unknown entry point: $output"
  contains "$output" "unknown native entry point 'build' (one of: prebuild app-config metro-start fingerprint)" || fail "output: $output"
}

@test "sourced, it exports the stack and names each stack's entry points" {
  run bash -c "set -euo pipefail
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/native-stack.sh'
    bash -c 'printf \"child sees %s\\n\" \"\$WORKFLOWS_NATIVE_STACK\"'
    workflows_native_script prebuild
    workflows_native_script fingerprint"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "child sees bare" || fail "WORKFLOWS_NATIVE_STACK was not exported: $output"
  contains "$output" "$REPO_ROOT/scripts/native/bare/prebuild.sh" || fail "output: $output"
  contains "$output" "$REPO_ROOT/scripts/native/bare/fingerprint.sh" || fail "output: $output"
}

@test "sourced with an invalid input, the sourcing script stops" {
  run bash -c "set -euo pipefail
    export WORKFLOWS_NATIVE_STACK_INPUT=android
    source '$REPO_ROOT/scripts/lib/common.sh'
    source '$REPO_ROOT/scripts/lib/native-stack.sh'
    echo reached"
  [ "$status" -ne 0 ] || fail "carried on: $output"
  not_contains "$output" "reached" || fail "carried on: $output"
}

@test "every entry point exists for both stacks" {
  local stack entry
  for stack in expo bare; do
    for entry in prebuild app-config metro-start fingerprint; do
      [ -f "$REPO_ROOT/scripts/native/$stack/$entry.sh" ] || fail "no scripts/native/$stack/$entry.sh"
    done
  done
}

@test "the fixture consumers resolve to their stacks: consumer-min to expo, consumer-bare to bare" {
  GITHUB_WORKSPACE="$FIXTURES/consumer-min" stack
  [ "$(last_line)" = expo ] || fail "consumer-min: $output"
  GITHUB_WORKSPACE="$FIXTURES/consumer-bare" stack
  [ "$(last_line)" = bare ] || fail "consumer-bare: $output"
  contains "$output" "expo is not a dependency in package.json" || fail "consumer-bare: $output"
}
