#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/bare/metro-start.sh, the bare stack's Metro: `react-native
# start` through pnpm in the background, in the consumer root, its log and PID
# in WORKFLOWS_OUT, on the configured port, and never --dev-client (an
# `expo start` flag). pnpm is a fake that records its call and directory.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$GITHUB_WORKSPACE"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'pnpm %s | CI=%s | cwd=%s\n' "$*" "${CI:-}" "$PWD"
STUB
  chmod +x "$bin/pnpm"
  export PATH="$bin:$PATH"
}

metro_log() {
  local i
  for i in $(seq 1 50); do
    [ -s "$WORKFLOWS_OUT/metro.log" ] && break
    sleep 0.2
  done
  cat "$WORKFLOWS_OUT/metro.log"
}

@test "starts react-native start in the consumer root on the default port, and records the log and PID" {
  run bash "$REPO_ROOT/scripts/native/bare/metro-start.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(metro_log)" = "pnpm exec react-native start --port 8081 | CI=1 | cwd=$(cd "$GITHUB_WORKSPACE" && pwd -P)" ] || fail "log: $(metro_log)"
  pid="$(cat "$WORKFLOWS_OUT/metro.pid")"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "not a PID: $pid"
  contains "$output" "Metro starting (pid $pid, port 8081, log $WORKFLOWS_OUT/metro.log)" || fail "output: $output"
  contains "$output" "stop it with: kill -TERM -$pid" || fail "output: $output"
}

@test "the configured port is used, and dev-client never adds a flag" {
  WORKFLOWS_DEV_CLIENT=true WORKFLOWS_METRO_PORT=9091 run bash "$REPO_ROOT/scripts/native/bare/metro-start.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(metro_log)" "pnpm exec react-native start --port 9091 | CI=1" || fail "log: $(metro_log)"
  not_contains "$(metro_log)" "--dev-client" || fail "an expo flag reached react-native: $(metro_log)"
}

@test "no pnpm on PATH is named, and nothing is started" {
  rm "$bin/pnpm"
  PATH="$bin:/usr/bin:/bin" run bash "$REPO_ROOT/scripts/native/bare/metro-start.sh"
  [ "$status" -ne 0 ] || fail "ran without pnpm: $output"
  contains "$output" "missing command: pnpm" || fail "output: $output"
  [ ! -f "$WORKFLOWS_OUT/metro.pid" ] || fail "wrote a PID anyway"
}
