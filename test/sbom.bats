#!/usr/bin/env bats
# scripts/security/sbom.sh - a CycloneDX bill of materials from
# pnpm-lock.yaml, written as <SECURITY_DIR>/sbom.cdx.json beside a clean SARIF
# whose note counts its components.
#
# Covers every way out of it: a bill with components, a bill that lists none
# (fails), pnpm failing, the job switched off, and pnpm missing - a skip
# locally, a failure under CI. pnpm is a fake on PATH that records its
# arguments and writes the bill FAKE_COMPONENTS describes.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY GITHUB_ACTIONS
  # shellcheck disable=SC2046  # one name per word
  unset $(compgen -e | grep '^SECURITY_' || true)
  mkdir -p "$BATS_TEST_TMPDIR/consumer"
  cd "$BATS_TEST_TMPDIR/consumer" || return 1
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
[ -z "${FAKE_EXIT:-}" ] || exit "$FAKE_EXIT"
while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
components="${FAKE_COMPONENTS:-}"
[ -n "$components" ] || components='[{},{},{}]'
printf '{"bomFormat":"CycloneDX","components":%s}' "$components" > "$out"
echo "pnpm's own chatter"
STUB
  chmod +x "$bin/pnpm"
}

bare_path() {
  local bare="$BATS_TEST_TMPDIR/bare-bin" tool
  mkdir -p "$bare"
  for tool in node bash env dirname basename mkdir cat grep sed; do
    ln -sf "$(command -v "$tool")" "$bare/$tool"
  done
  printf '%s' "$bare"
}

sarif_note() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(d.runs[0].invocations[0].toolExecutionNotifications[0].message.text)' "$1"
}

scan() { PATH="$bin:$PATH" run bash "$REPO_ROOT/scripts/security/sbom.sh"; }

@test "writes the bill beside a clean SARIF that counts its components" {
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(cat "$CALLS")" = "sbom --sbom-format cyclonedx --sbom-type application --lockfile-only --out .security/sbom.cdx.json" ] ||
    fail "pnpm was called as: $(cat "$CALLS")"
  [ -s .security/sbom.cdx.json ] || fail "no bill written"
  [ "$(sarif_note .security/sbom.sarif)" = "3 components in the bill of materials" ] ||
    fail "note: $(sarif_note .security/sbom.sarif)"
  not_contains "$output" "pnpm's own chatter" || fail "pnpm's stdout was not silenced: $output"
  contains "$output" "sbom: wrote .security/sbom.cdx.json and .security/sbom.sarif" || fail "output: $output"
}

@test "a bill that lists nothing fails the job rather than reading as clean" {
  FAKE_COMPONENTS='[]' scan
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "no components" || fail "output: $output"
  not_contains "$output" "sbom: wrote" || fail "reported success: $output"
}

@test "a pnpm failure fails the job" {
  FAKE_EXIT=3 scan
  [ "$status" -eq 3 ] || fail "expected pnpm's 3, got $status: $output"
  [ ! -e .security/sbom.sarif ] || fail "wrote a SARIF after pnpm failed"
}

@test "switched off, it writes a skipped SARIF and never calls pnpm" {
  SECURITY_SBOM=false scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note .security/sbom.sarif)" disabled || fail "the SARIF does not say disabled"
  [ ! -s "$CALLS" ] || fail "pnpm ran: $(cat "$CALLS")"
}

@test "without pnpm it skips locally" {
  PATH="$(bare_path)" run bash "$REPO_ROOT/scripts/security/sbom.sh"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note .security/sbom.sarif)" "pnpm is not installed" || fail "wrong skip note"
}

@test "without pnpm it fails under CI" {
  CI=true PATH="$(bare_path)" run bash "$REPO_ROOT/scripts/security/sbom.sh"
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "pnpm is not installed" || fail "output: $output"
  [ ! -e .security/sbom.sarif ] || fail "a CI failure wrote a skipped SARIF"
}
