#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# The OTA scripts as one pipeline: baseline -> (gate) -> export -> publish ->
# smoke. Each script has its own test file, which covers its exit paths:
# test/baseline.bats, test/fingerprint-gate.bats, test/ota-export.bats,
# test/publish.bats and test/smoke.bats. This file holds only the property
# that spans two of them: what publish uploads has to be what export produced
# and the gate vetted, never a second export made after the gate ran.
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

# Records its argv; `expo export` writes an export into --output-dir.
stub_npx() {
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
prev=""; out=""
for a in "$@"; do [ "$prev" = "--output-dir" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then
  mkdir -p "$out"
  printf '{"exported":"once"}\n' > "$out/metadata.json"
  printf 'bundle\n' > "$out/index.js"
fi
exit 0
SH
  chmod +x "$STUB/npx"
}

@test "publish uploads exactly the export that export.sh produced, without exporting again" {
  stub_npx
  run bash "$REPO_ROOT/scripts/ota/export.sh"
  [ "$status" -eq 0 ] || fail "export exited $status: $output"
  before="$(cat "$WORKFLOWS_OTA_DIR/metadata.json")"
  OTA_ENABLED=true OTA_CLI_VERSION=1.2.3 run bash "$REPO_ROOT/scripts/ota/publish.sh" beta 25
  [ "$status" -eq 0 ] || fail "publish exited $status: $output"
  [ "$(grep -c '^npx expo export' "$WORKFLOWS_TEST_LOG")" -eq 1 ] \
    || fail "the update was exported more than once: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -q -- "^npx eoas@1.2.3 publish .*--input-dir $WORKFLOWS_OTA_DIR .*--skip-bundler" "$WORKFLOWS_TEST_LOG" \
    || fail "publish did not upload the exported directory as it stands: $(cat "$WORKFLOWS_TEST_LOG")"
  [ "$(cat "$WORKFLOWS_OTA_DIR/metadata.json")" = "$before" ] || fail "the export changed between export and publish"
}
