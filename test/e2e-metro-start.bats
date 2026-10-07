#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/metro-start.sh: the thin dispatcher test-e2e.yml calls. The
# consumer's native stack picks the command - `expo start` for the Expo
# fixture, `react-native start` for the bare one - and both keep the same log
# and PID contract. pnpm is a fake that records its call and exits. The stacks'
# own cases are in native-expo-metro-start.bats and native-bare-metro-start.bats.
load test_helper

setup() {
  export WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'pnpm %s | CI=%s\n' "$*" "${CI:-}"
STUB
  as_fakes "$bin/pnpm"
  export PATH="$bin:$PATH"
  unset WORKFLOWS_NATIVE_STACK_INPUT
}

# The background fake has written its whole line into the log: wait_for polls
# this instead of reading the log once, which under a parallel run read it
# before the fake had started.
metro_logged() {
  [ -s "$WORKFLOWS_OUT/metro.log" ] && [ -z "$(tail -c 1 "$WORKFLOWS_OUT/metro.log")" ]
}

metro_log() { cat "$WORKFLOWS_OUT/metro.log"; }

@test "the Expo fixture gets expo start, with the log and PID recorded" {
  GITHUB_WORKSPACE="$FIXTURES/consumer-min" run bash "$REPO_ROOT/scripts/e2e/metro-start.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  wait_for 60 "the fake pnpm's line in metro.log" metro_logged
  [ "$(metro_log)" = "pnpm exec expo start --port 8081 --dev-client | CI=1" ] || fail "log: $(metro_log)"
  [ -s "$WORKFLOWS_OUT/metro.pid" ] || fail "no PID file"
}

@test "the bare fixture gets react-native start, with the same log and PID contract" {
  GITHUB_WORKSPACE="$FIXTURES/consumer-bare" run bash "$REPO_ROOT/scripts/e2e/metro-start.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "native stack: bare" || fail "the stack was not detected: $output"
  wait_for 60 "the fake pnpm's line in metro.log" metro_logged
  [ "$(metro_log)" = "pnpm exec react-native start --port 8081 | CI=1" ] || fail "log: $(metro_log)"
  pid="$(cat "$WORKFLOWS_OUT/metro.pid")"
  contains "$output" "stop it with: kill -TERM -$pid" || fail "output: $output"
}

@test "the native-stack input overrides detection" {
  WORKFLOWS_NATIVE_STACK_INPUT=bare GITHUB_WORKSPACE="$FIXTURES/consumer-min" run bash "$REPO_ROOT/scripts/e2e/metro-start.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  wait_for 60 "the fake pnpm's line in metro.log" metro_logged
  [ "$(metro_log)" = "pnpm exec react-native start --port 8081 | CI=1" ] || fail "log: $(metro_log)"
}

@test "an invalid native-stack input starts nothing" {
  WORKFLOWS_NATIVE_STACK_INPUT=web GITHUB_WORKSPACE="$FIXTURES/consumer-min" run bash "$REPO_ROOT/scripts/e2e/metro-start.sh"
  [ "$status" -ne 0 ] || fail "accepted web: $output"
  [ ! -f "$WORKFLOWS_OUT/metro.pid" ] || fail "started Metro anyway"
}
