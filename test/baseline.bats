#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ota/baseline.sh: fetching the fingerprint baseline for an OTA channel
# from the release that produced the installed store build. Covers the download
# into the default and a given destination, and every way it refuses: no gh, no
# tag, a failed download, an empty asset, and a stale baseline left behind.
#
# The baseline must come from a *release asset*: download-artifact can only see
# the current run, so a same-run artifact would compare the commit against
# itself and the gate would pass unconditionally.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/cmd.log"
  : > "$WORKFLOWS_TEST_LOG"
  export PATH="$STUB:$PATH"
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_OTA_DIR="$BATS_TEST_TMPDIR/ota" WORKFLOWS_ASSETS_DIR="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_ENV
}

stub_gh() {
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
prev=""; out=""
for a in "$@"; do [ "$prev" = "--output" ] && out="$a"; prev="$a"; done
[ -f "$WORKFLOWS_TEST_ASSET_MISSING" ] && exit 1
[ -n "$out" ] || exit 1
printf '%s' "$WORKFLOWS_TEST_ASSET_BODY" > "$out"
exit 0
SH
  chmod +x "$STUB/gh"
  export WORKFLOWS_TEST_ASSET_MISSING="$BATS_TEST_TMPDIR/asset-missing"
  export WORKFLOWS_TEST_ASSET_BODY='{"sha":"abc","fingerprint":{"ios":"fp"}}'
}

baseline() { run bash "$REPO_ROOT/scripts/ota/baseline.sh" "$@"; }

@test "baseline downloads build-info.json from the channel's release" {
  stub_gh
  baseline v1.2.3
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q '^release download v1.2.3 --pattern build-info.json' "$WORKFLOWS_TEST_LOG" \
    || fail "unexpected gh argv: $(cat "$WORKFLOWS_TEST_LOG")"
  [ -s "$WORKFLOWS_ASSETS_DIR/build-info.json" ] || fail "no baseline was written"
}

@test "baseline without a tag is fatal, and says which input is missing" {
  stub_gh
  baseline
  [ "$status" -ne 0 ] || fail "accepted an empty tag: $output"
  contains "$output" "baseline-tag" || fail "unexpected message: $output"
}

@test "a release with no build-info.json asset is fatal, never a silent pass" {
  stub_gh
  : > "$WORKFLOWS_TEST_ASSET_MISSING"
  baseline v1.2.3
  [ "$status" -ne 0 ] || fail "accepted a release with no baseline asset: $output"
  contains "$output" "could not download build-info.json" || fail "unexpected message: $output"
}

@test "an empty build-info.json asset is fatal" {
  stub_gh
  WORKFLOWS_TEST_ASSET_BODY='' baseline v1.2.3
  [ "$status" -ne 0 ] || fail "accepted an empty baseline: $output"
  contains "$output" "no fingerprint baseline" || fail "unexpected message: $output"
}

@test "a stale baseline from an earlier run is removed before the download" {
  stub_gh
  mkdir -p "$WORKFLOWS_ASSETS_DIR"
  printf 'stale\n' > "$WORKFLOWS_ASSETS_DIR/build-info.json"
  : > "$WORKFLOWS_TEST_ASSET_MISSING"
  baseline v1.2.3
  [ "$status" -ne 0 ] || fail "the stale file was accepted as a baseline: $output"
  [ ! -f "$WORKFLOWS_ASSETS_DIR/build-info.json" ] || fail "the stale baseline survived a failed download"
}

@test "a destination given as the second argument is where the baseline lands, and it is logged" {
  stub_gh
  dest="$BATS_TEST_TMPDIR/elsewhere/nested/baseline.json"
  baseline v1.2.3 "$dest"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q -- "--output $dest" "$WORKFLOWS_TEST_LOG" || fail "gh did not write to the given destination: $(cat "$WORKFLOWS_TEST_LOG")"
  [ -s "$dest" ] || fail "no baseline at the given destination"
  [ ! -f "$WORKFLOWS_ASSETS_DIR/build-info.json" ] || fail "the default destination was written as well"
  contains "$output" "baseline for the gate: $dest" || fail "the destination was not logged: $output"
  contains "$output" '"fingerprint":{"ios":"fp"}' || fail "the baseline itself was not logged: $output"
}

@test "without gh on PATH it is fatal before any download, and names the command" {
  # A PATH of symlinks to exactly what the script runs before its gh check: the
  # runner images ship a gh in /usr/bin, which would satisfy the lookup.
  nogh="$BATS_TEST_TMPDIR/nogh"
  mkdir -p "$nogh"
  for c in bash dirname mkdir; do
    p="$(command -v "$c")" && ln -sf "$p" "$nogh/$c"
  done
  PATH="$nogh" baseline v1.2.3
  [ "$status" -ne 0 ] || fail "ran without gh: $output"
  contains "$output" "missing command: gh" || fail "unexpected message: $output"
  [ ! -e "$WORKFLOWS_ASSETS_DIR/build-info.json" ] || fail "a baseline appeared without gh"
}
