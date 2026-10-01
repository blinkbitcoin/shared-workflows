#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/expo-only.sh: check.yml's Expo health step. It resolves the
# consumer's native stack with packages/app-tooling/lib/native-stack.mjs
# (NATIVE_STACK first) and runs the gate through run-consumer-or.sh on the
# Expo stack, or passes with a notice on a bare React Native app.
#
# Covered: an Expo consumer (detected, and named by NATIVE_STACK over a bare
# repository) running the consumer's script, a bare consumer (detected, and
# named by NATIVE_STACK over an Expo repository) skipping with the notice and
# running nothing, an Expo app whose committed ios/ makes it bare, an invalid
# NATIVE_STACK failing the step, the usage refusals, no node, and no resolver
# beside the script.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/expo-only.sh"

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  unset NATIVE_STACK
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export WORKFLOWS_TEST_CALLS="$CALLS"
  # A pnpm that records what it was asked to run.
  printf '#!/usr/bin/env bash\nprintf "pnpm %%s\\n" "$*" >> "$WORKFLOWS_TEST_CALLS"\n' > "$STUB/pnpm"
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
}

# A consumer with its own check:expo-health script, and expo as a dependency or not.
write_consumer() { # expo|none
  local deps='{}'
  [ "$1" = expo ] && deps='{"expo":"~57.0.0"}'
  printf '{"name":"app","dependencies":%s,"scripts":{"check:expo-health":"true"}}\n' "$deps" > "$CONSUMER/package.json"
}

run_gate() { run bash "$SCRIPT" 'check:expo-health' scripts/checks/expo-health.sh; }

@test "an Expo app runs the gate, its own script first" {
  write_consumer expo
  run_gate
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(cat "$CALLS")" = 'pnpm run check:expo-health' ] || fail "the gate did not run the consumer's script: $(cat "$CALLS")"
  contains "$output" 'native stack: expo (expo is a dependency and git tracks no ios/)' || fail "the stack is not logged: $output"
  not_contains "$output" '::notice' || fail "an Expo app was told the gate does not apply: $output"
}

@test "a bare app skips the gate with a notice and runs nothing" {
  write_consumer none
  run_gate
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -s "$CALLS" ] || fail "the gate ran on a bare app: $(cat "$CALLS")"
  contains "$output" '::notice title=check:expo-health skipped::check:expo-health is an Expo gate, and this repository is the bare stack' \
    || fail "the skip is not a notice naming the stack: $output"
  contains "$output" 'Pass native-stack: expo if that is wrong.' || fail "the notice does not say how to override it: $output"
}

@test "an Expo dependency with a committed ios/ is a bare app" {
  write_consumer expo
  mkdir -p "$CONSUMER/ios"
  : > "$CONSUMER/ios/Podfile"
  git -C "$CONSUMER" init -q
  git -C "$CONSUMER" add ios/Podfile
  run_gate
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -s "$CALLS" ] || fail "the gate ran on a committed ios/: $(cat "$CALLS")"
  contains "$output" 'git tracks ios/' || fail "the reason is not logged: $output"
}

@test "NATIVE_STACK decides over the repository, either way" {
  write_consumer none
  NATIVE_STACK=expo run_gate
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(cat "$CALLS")" = 'pnpm run check:expo-health' ] || fail "native-stack: expo did not run the gate: $(cat "$CALLS")"
  : > "$CALLS"
  write_consumer expo
  NATIVE_STACK=bare run_gate
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -s "$CALLS" ] || fail "native-stack: bare still ran the gate: $(cat "$CALLS")"
}

@test "a NATIVE_STACK that is not a stack fails the step instead of skipping it" {
  write_consumer expo
  NATIVE_STACK=native run_gate
  [ "$status" -eq 1 ] || fail "an invalid stack passed with $status: $output"
  contains "$output" '::error::native-stack is "native": expected expo, bare or empty' || fail "the error: $output"
  [ ! -s "$CALLS" ] || fail "the gate ran on an invalid stack"
}

@test "both arguments are required" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "no arguments passed"
  contains "$output" 'usage: expo-only.sh NAME FALLBACK' || fail "the usage: $output"
  run bash "$SCRIPT" 'check:expo-health'
  [ "$status" -ne 0 ] || fail "one argument passed"
  contains "$output" 'usage: expo-only.sh NAME FALLBACK' || fail "the usage: $output"
}

@test "a runner without node is refused before anything runs" {
  local bare="$BATS_TEST_TMPDIR/bare-path"
  mkdir -p "$bare"
  ln -s "$(command -v dirname)" "$bare/dirname"
  run env PATH="$bare" "$BASH" "$SCRIPT" 'check:expo-health' scripts/checks/expo-health.sh
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'missing command: node' || fail "the error: $output"
}

@test "a checkout without the resolver beside the script is refused, naming the path" {
  local copy="$BATS_TEST_TMPDIR/workflows"
  mkdir -p "$copy/scripts/checks" "$copy/scripts/lib"
  cp "$SCRIPT" "$copy/scripts/checks/"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$copy/scripts/lib/"
  run bash "$copy/scripts/checks/expo-only.sh" 'check:expo-health' scripts/checks/expo-health.sh
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "expo-only.sh: no stack resolver at $copy/packages/app-tooling/lib/native-stack.mjs" || fail "the error: $output"
}
