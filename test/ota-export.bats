#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ota/export.sh: the `expo export` that produces the OTA update, with
# source maps, into $WORKFLOWS_OTA_DIR. Covers the export itself, where it runs,
# clearing a previous export, and every way it fails: no npx, a working
# directory that does not exist, a failing export, an empty one, and one with no
# metadata.json. (test/export.bats is scripts/web/export.sh's own test.)
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
  unset GITHUB_ENV
}

# Records its argv, the token and the working directory, and writes an export
# into --output-dir unless told to produce nothing or no metadata.json.
stub_npx() {
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
printf 'EXPO_TOKEN=%s\n' "${EXPO_TOKEN-}" >> "$WORKFLOWS_TEST_LOG"
printf 'cwd=%s CI=%s\n' "$PWD" "${CI-}" >> "$WORKFLOWS_TEST_LOG"
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

export_ota() { run bash "$REPO_ROOT/scripts/ota/export.sh"; }

@test "export writes source maps into WORKFLOWS_OTA_DIR" {
  stub_npx
  export_ota
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(grep '^npx expo export' "$WORKFLOWS_TEST_LOG")"
  contains "$argv" "--source-maps" || fail "the source maps are not exported: $argv"
  contains "$argv" "--platform all" || fail "not both platforms: $argv"
  contains "$argv" "--output-dir $WORKFLOWS_OTA_DIR" || fail "wrong output dir: $argv"
  [ -f "$WORKFLOWS_OTA_DIR/metadata.json" ] || fail "no export landed"
}

@test "export clears a previous export rather than mixing two" {
  stub_npx
  mkdir -p "$WORKFLOWS_OTA_DIR"
  printf 'old\n' > "$WORKFLOWS_OTA_DIR/stale.js"
  export_ota
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -f "$WORKFLOWS_OTA_DIR/stale.js" ] || fail "a file from the previous export survived"
}

# `mkdir -p` above the export makes `[ -d ]` an assertion that cannot fail, so
# the content is what gets asserted.
@test "an export that produces nothing is fatal" {
  stub_npx
  WORKFLOWS_TEST_EXPORT_EMPTY=true export_ota
  [ "$status" -ne 0 ] || fail "accepted an empty export: $output"
  contains "$output" "produced no output" || fail "unexpected message: $output"
}

@test "an export without metadata.json is fatal" {
  stub_npx
  WORKFLOWS_TEST_NO_METADATA=true export_ota
  [ "$status" -ne 0 ] || fail "accepted an export with no metadata.json: $output"
  contains "$output" "no metadata.json" || fail "unexpected message: $output"
}

@test "a failing expo export is fatal" {
  stub_npx
  WORKFLOWS_TEST_NPX_STATUS=1 export_ota
  [ "$status" -ne 0 ] || fail "a failed export was ignored: $output"
}

@test "export runs in the consumer's working directory, as CI, and lists what it wrote" {
  stub_npx
  export_ota
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  root="$(cd "$ROOT" && pwd -P)"
  grep -qx "cwd=$root CI=1" "$WORKFLOWS_TEST_LOG" \
    || fail "expo export did not run in the consumer root with CI=1: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "ota export contents:" || fail "the export was not listed: $output"
  contains "$output" "metadata.json" || fail "the listing does not show the export: $output"
}

@test "a working directory that does not exist is fatal before anything is exported" {
  stub_npx
  WORKING_DIRECTORY=missing export_ota
  [ "$status" -ne 0 ] || fail "exported from a working directory that does not exist: $output"
  ! grep -q '^npx ' "$WORKFLOWS_TEST_LOG" || fail "ran expo export anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "without npx on PATH it is fatal, and a previous export is left alone" {
  # A PATH of symlinks to exactly what the script runs before its npx check, so
  # an npx installed on this machine cannot satisfy the lookup.
  nonpx="$BATS_TEST_TMPDIR/nonpx"
  mkdir -p "$nonpx" "$WORKFLOWS_OTA_DIR"
  for c in bash dirname mkdir; do
    p="$(command -v "$c")" && ln -sf "$p" "$nonpx/$c"
  done
  printf 'previous\n' > "$WORKFLOWS_OTA_DIR/index.js"
  PATH="$nonpx" export_ota
  [ "$status" -ne 0 ] || fail "ran without npx: $output"
  contains "$output" "missing command: npx" || fail "unexpected message: $output"
  [ -f "$WORKFLOWS_OTA_DIR/index.js" ] || fail "the previous export was cleared before the check"
}
