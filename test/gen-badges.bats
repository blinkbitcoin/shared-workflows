#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/gen-badges.sh, publish-badges.yml's render step: its own test.
# By default it runs @blinkbitcoin/app-tooling's gen-badges from this
# checkout, in the consumer root; a caller's `badges-script` hands the render
# to that consumer script through run-script.sh instead. The renderer's own
# cases are in packages/app-tooling/gen-badges.test.mjs; these are the
# wrapper's: which renderer, where it runs, and each way it fails.
load test_helper

SCRIPT="$REPO_ROOT/scripts/ci/gen-badges.sh"

setup() {
  # consumer_root() is GITHUB_WORKSPACE + WORKING_DIRECTORY, as on a runner
  # after the setup action.
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/workspace"
  export WORKING_DIRECTORY=app
  CONSUMER="$GITHUB_WORKSPACE/app"
  mkdir -p "$CONSUMER"
  printf '{"name":"c","scripts":{"badges:render":"node -e 0"}}\n' > "$CONSUMER/package.json"
  export BADGE_UNIT=skipped BADGE_E2E=success
  unset RENDER_SCRIPT BADGE_OUT_DIR BADGE_COVERAGE BADGE_SECURITY
  # pnpm is only reached through run-script.sh; the stub records the call so a
  # case can tell the consumer's script ran without installing anything.
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "pnpm $*" >> "$WORKFLOWS_TEST_LOG"
SH
  chmod +x "$STUB/pnpm"
  PATH="$STUB:$PATH"
  export PATH WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$WORKFLOWS_TEST_LOG"
}

@test "by default it renders with the package's gen-badges, into the consumer root" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "rendering with @blinkbitcoin/app-tooling's gen-badges" \
    || fail "the log does not say which renderer ran: $output"
  grep -q 'passing' "$CONSUMER/coverage/badge/e2e.svg" || fail "no e2e badge in the consumer's coverage/badge"
  [ -f "$CONSUMER/coverage/badge/unit.svg" ] || fail "no unit badge in the consumer's coverage/badge"
  [ ! -e "$CONSUMER/coverage/badge/coverage.svg" ] || fail "a skipped Unit rendered a coverage badge"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "a consumer script ran as well: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "BADGE_OUT_DIR is read relative to the consumer root, not the step's directory" {
  cd "$BATS_TEST_TMPDIR"
  BADGE_OUT_DIR=site/badges run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -f "$CONSUMER/site/badges/e2e.svg" ] || fail "the badges did not land under the consumer root"
  [ ! -e "$BATS_TEST_TMPDIR/site" ] || fail "the badges landed in the step's own directory"
}

@test "a badges-script hands the render to that consumer script instead" {
  RENDER_SCRIPT='badges:render' run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "rendering with the consumer's \"badges:render\" script" \
    || fail "the log does not say the consumer's script ran: $output"
  grep -qx 'pnpm run badges:render' "$WORKFLOWS_TEST_LOG" \
    || fail "the consumer's script did not run: $(cat "$WORKFLOWS_TEST_LOG")"
  [ ! -e "$CONSUMER/coverage/badge" ] || fail "the package's renderer ran as well"
}

@test "a badges-script the consumer does not ship fails with the fix" {
  RENDER_SCRIPT='badges:mine' run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "exited $status for a missing script: $output"
  contains "$output" 'consumer package.json has no "badges:mine" script' || fail "output: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "something ran: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a result the renderer does not know fails the step with its reason" {
  BADGE_UNIT=green run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "exited $status for an unknown result: $output"
  contains "$output" 'unknown job result "green"' || fail "output: $output"
}

@test "a working directory that does not exist is fatal" {
  WORKING_DIRECTORY=missing run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "rendered without a consumer root: $output"
  [ ! -e "$GITHUB_WORKSPACE/coverage" ] || fail "it rendered into the workspace instead"
}

@test "a checkout without the package's renderer is fatal, and names the path" {
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/scripts/ci" "$tree/scripts/lib"
  cp "$SCRIPT" "$tree/scripts/ci/"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$tree/scripts/lib/"
  run bash "$tree/scripts/ci/gen-badges.sh"
  [ "$status" -eq 1 ] || fail "exited $status without a renderer: $output"
  contains "$output" "no renderer at $tree/packages/app-tooling/bin/gen-badges.mjs" || fail "output: $output"
}

@test "without node it is fatal, and names the command" {
  nonode="$BATS_TEST_TMPDIR/nonode"
  mkdir -p "$nonode"
  for c in bash dirname; do
    p="$(command -v "$c")" && ln -sf "$p" "$nonode/$c"
  done
  PATH="$nonode" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "ran without node: $output"
  contains "$output" "missing command: node" || fail "output: $output"
}
