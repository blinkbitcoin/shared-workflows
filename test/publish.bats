#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ota/publish.sh: publishing the export in $WORKFLOWS_OTA_DIR to a
# channel at a rollout percentage, with the pinned CLI. Covers the publish with
# and without a token, where it runs, the OTA_ENABLED guard, and every way it
# refuses: no npx, a missing channel or rollout, an unpinned CLI, a rollout that
# is not an integer from 0 to 100, no export, a working directory that does not
# exist, and a failing CLI.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  ROOT="$BATS_TEST_TMPDIR/app"
  mkdir -p "$STUB" "$ROOT"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/cmd.log"
  : > "$WORKFLOWS_TEST_LOG"
  export PATH="$STUB:$PATH"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=app
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_OTA_DIR="$BATS_TEST_TMPDIR/ota" WORKFLOWS_ASSETS_DIR="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_ENV OTA_ENABLED OTA_CLI_VERSION OTA_PUBLISH_TOKEN
}

# Records its argv, the token and the working directory, and exits with
# $WORKFLOWS_TEST_NPX_STATUS.
stub_npx() {
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
printf 'EXPO_TOKEN=%s\n' "${EXPO_TOKEN-}" >> "$WORKFLOWS_TEST_LOG"
printf 'cwd=%s\n' "$PWD" >> "$WORKFLOWS_TEST_LOG"
prev=""; out=""
for a in "$@"; do [ "$prev" = "--output-dir" ] && out="$a"; prev="$a"; done
if [ -n "$out" ] && [ "${WORKFLOWS_TEST_EXPORT_EMPTY:-}" != "true" ]; then
  mkdir -p "$out"
  printf '{}\n' > "$out/metadata.json"
  printf 'bundle\n' > "$out/index.js"
  [ "${WORKFLOWS_TEST_NO_METADATA:-}" = "true" ] && rm -f "$out/metadata.json"
fi
exit "${WORKFLOWS_TEST_NPX_STATUS:-0}"
SH
  chmod +x "$STUB/npx"
}

publish() { run bash "$REPO_ROOT/scripts/ota/publish.sh" "$@"; }
seed_export() { mkdir -p "$WORKFLOWS_OTA_DIR"; printf '{}\n' > "$WORKFLOWS_OTA_DIR/metadata.json"; }

# I4: the export the gate vetted is what gets published, and the token the
# workflow passes in is actually handed to the CLI.
@test "publish uploads the export in WORKFLOWS_OTA_DIR, with the token" {
  stub_npx
  seed_export
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 OTA_PUBLISH_TOKEN=tok-123 publish beta 25
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(grep '^npx eoas' "$WORKFLOWS_TEST_LOG")"
  contains "$argv" "eoas@1.2.3 publish" || fail "the CLI is not pinned: $argv"
  contains "$argv" "--branch beta" || fail "wrong channel: $argv"
  contains "$argv" "--rollout-percentage 25" || fail "wrong rollout: $argv"
  contains "$argv" "--input-dir $WORKFLOWS_OTA_DIR" || fail "the vetted export is not what gets published: $argv"
  contains "$argv" "--skip-bundler" || fail "--input-dir without --skip-bundler re-exports: $argv"
  contains "$argv" "--non-interactive" || fail "not non-interactive: $argv"
  grep -qx 'EXPO_TOKEN=tok-123' "$WORKFLOWS_TEST_LOG" || fail "OTA_PUBLISH_TOKEN never reached the CLI: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "publish without a token still runs, and says so" {
  stub_npx
  seed_export
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 0
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "OTA_PUBLISH_TOKEN is not set" || fail "unexpected message: $output"
  grep -qx 'EXPO_TOKEN=' "$WORKFLOWS_TEST_LOG" || fail "an empty token was invented: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "publish is a no-op unless OTA_ENABLED is exactly true" {
  stub_npx
  seed_export
  OTA_CLI_VERSION=1.2.3 publish beta 0
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  ! grep -q '^npx eoas' "$WORKFLOWS_TEST_LOG" || fail "published with OTA_ENABLED unset"
  OTA_ENABLED=yes OTA_CLI_VERSION=1.2.3 publish beta 0
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  ! grep -q '^npx eoas' "$WORKFLOWS_TEST_LOG" || fail "published with OTA_ENABLED=yes"
}

# Never publish from an unpinned CLI: the update format can change between runs.
@test "publish without a pinned CLI version is fatal" {
  stub_npx
  seed_export
  OTA_ENABLED=true publish beta 0
  [ "$status" -ne 0 ] || fail "published from an unpinned CLI: $output"
  contains "$output" "OTA_CLI_VERSION" || fail "unexpected message: $output"
}

@test "a rollout that is not an integer percentage is fatal" {
  stub_npx
  seed_export
  for r in 10.5 abc -1 101 ''; do
    OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta "$r"
    [ "$status" -ne 0 ] || fail "accepted the rollout '$r': $output"
  done
  ! grep -q '^npx eoas' "$WORKFLOWS_TEST_LOG" || fail "published despite a bad rollout"
}

@test "publish without an export is fatal, and names the script that makes one" {
  stub_npx
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 0
  [ "$status" -ne 0 ] || fail "published with no export: $output"
  contains "$output" "export.sh" || fail "unexpected message: $output"
  mkdir -p "$WORKFLOWS_OTA_DIR"
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 0
  [ "$status" -ne 0 ] || fail "published with an empty export directory: $output"
}

@test "each rejected rollout says why: not an integer, or out of range" {
  stub_npx
  seed_export
  for r in 10.5 abc -1; do
    OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta "$r"
    [ "$status" -ne 0 ] || fail "accepted the rollout '$r': $output"
    contains "$output" "must be an integer percentage 0-100 (got '$r')" || fail "unexpected message for '$r': $output"
  done
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 101
  [ "$status" -ne 0 ] || fail "accepted the rollout 101: $output"
  contains "$output" "must be between 0 and 100 (got '101')" || fail "unexpected message for 101: $output"
}

@test "the rollout bounds 0 and 100 are both accepted" {
  stub_npx
  seed_export
  for r in 0 100; do
    OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta "$r"
    [ "$status" -eq 0 ] || fail "rejected the rollout $r: $output"
    grep -q -- "--rollout-percentage $r " "$WORKFLOWS_TEST_LOG" || fail "did not publish at $r: $(cat "$WORKFLOWS_TEST_LOG")"
  done
}

@test "a missing channel or rollout is fatal, with the usage" {
  stub_npx
  seed_export
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish
  [ "$status" -ne 0 ] || fail "published without a channel: $output"
  contains "$output" "usage: publish.sh CHANNEL ROLLOUT" || fail "no usage for a missing channel: $output"
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta
  [ "$status" -ne 0 ] || fail "published without a rollout: $output"
  contains "$output" "usage: publish.sh CHANNEL ROLLOUT" || fail "no usage for a missing rollout: $output"
  ! grep -q '^npx eoas' "$WORKFLOWS_TEST_LOG" || fail "published despite a missing argument"
}

@test "publish runs from the consumer's working directory" {
  stub_npx
  seed_export
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 10
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  root="$(cd "$ROOT" && pwd -P)"
  grep -qx "cwd=$root" "$WORKFLOWS_TEST_LOG" || fail "did not publish from the consumer root: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a working directory that does not exist is fatal before anything is published" {
  stub_npx
  seed_export
  WORKING_DIRECTORY=missing OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 10
  [ "$status" -ne 0 ] || fail "published from a working directory that does not exist: $output"
  ! grep -q '^npx eoas' "$WORKFLOWS_TEST_LOG" || fail "published anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a failing publish is fatal" {
  stub_npx
  seed_export
  WORKFLOWS_TEST_NPX_STATUS=1 OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 10
  [ "$status" -ne 0 ] || fail "a failed publish was ignored: $output"
  grep -q '^npx eoas' "$WORKFLOWS_TEST_LOG" || fail "the CLI never ran: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "without npx on PATH it is fatal, and names the command" {
  # A PATH of symlinks to exactly what the script runs before its npx check, so
  # an npx installed on this machine cannot satisfy the lookup.
  nonpx="$BATS_TEST_TMPDIR/nonpx"
  mkdir -p "$nonpx"
  for c in bash dirname mkdir; do
    p="$(command -v "$c")" && ln -sf "$p" "$nonpx/$c"
  done
  seed_export
  PATH="$nonpx" OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 publish beta 10
  [ "$status" -ne 0 ] || fail "ran without npx: $output"
  contains "$output" "missing command: npx" || fail "unexpected message: $output"
}
