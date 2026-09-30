#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/metro-start.sh: Metro in the background, its log and PID in
# WORKFLOWS_OUT, on the configured port, with --dev-client unless the build
# embeds its own bundle. pnpm is a fake that records its call and exits.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$GITHUB_WORKSPACE"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'pnpm %s | CI=%s\n' "$*" "${CI:-}"
STUB
  chmod +x "$bin/pnpm"
  export PATH="$bin:$PATH"
}

# Waits for the background fake to write its line into the log.
metro_log() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$WORKFLOWS_OUT/metro.log" ] && break
    sleep 0.2
  done
  cat "$WORKFLOWS_OUT/metro.log"
}

@test "starts expo on the default port with --dev-client, and records the log and PID" {
  run bash "$REPO_ROOT/scripts/e2e/metro-start.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(metro_log)" = "pnpm exec expo start --port 8081 --dev-client | CI=1" ] || fail "log: $(metro_log)"
  pid="$(cat "$WORKFLOWS_OUT/metro.pid")"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "not a PID: $pid"
  contains "$output" "Metro starting (pid $pid, port 8081, log $WORKFLOWS_OUT/metro.log)" || fail "output: $output"
  contains "$output" "stop it with: kill -TERM -$pid" || fail "output: $output"
}

@test "a Release build gets no --dev-client, on the configured port" {
  WORKFLOWS_DEV_CLIENT=false WORKFLOWS_METRO_PORT=9090 run bash "$REPO_ROOT/scripts/e2e/metro-start.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(metro_log)" = "pnpm exec expo start --port 9090 | CI=1" ] || fail "log: $(metro_log)"
}

@test "no pnpm on PATH is named, and nothing is started" {
  rm "$bin/pnpm"
  PATH="$bin:/usr/bin:/bin" run bash "$REPO_ROOT/scripts/e2e/metro-start.sh"
  [ "$status" -ne 0 ] || fail "ran without pnpm: $output"
  contains "$output" "missing command: pnpm" || fail "output: $output"
  [ ! -f "$WORKFLOWS_OUT/metro.pid" ] || fail "wrote a PID anyway"
}
