#!/usr/bin/env bats
# scripts/security/dependencies.sh - osv-scanner over pnpm-lock.yaml, written
# as <SECURITY_DIR>/dependencies.sarif. osv-scanner's exit 1 means "findings"
# and is accepted; anything above it fails the runner.
#
# Covers every way out of it: a clean scan, findings (exit 1, accepted), an
# osv-scanner error (exit 2, fails), the job switched off, an invalid switch,
# and osv-scanner missing - a skip locally, a failure under CI. osv-scanner is
# a fake on PATH that records how it was called.
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
  # Records its arguments, writes a SARIF to --output-file, exits FAKE_EXIT.
  cat > "$bin/osv-scanner" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = --output-file ] && out="$2"; shift; done
printf '{"version":"2.1.0","runs":[]}' > "$out"
exit "${FAKE_EXIT:-0}"
STUB
  as_fakes "$bin/osv-scanner"
}

# A PATH with node and the basics a runner needs, and no scanner - so "missing"
# is true even on a machine that has osv-scanner installed.
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

scan() { PATH="$bin:$PATH" run bash "$REPO_ROOT/scripts/security/dependencies.sh"; }

@test "a clean scan runs osv-scanner over the lockfile into dependencies.sarif" {
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(cat "$CALLS")" = "scan source --lockfile pnpm-lock.yaml --format sarif --output-file .security/dependencies.sarif" ] ||
    fail "osv-scanner was called as: $(cat "$CALLS")"
  [ -s .security/dependencies.sarif ] || fail "no SARIF written"
  contains "$output" "dependencies: wrote .security/dependencies.sarif" || fail "output: $output"
}

@test "SECURITY_DIR moves the SARIF" {
  SECURITY_DIR="$BATS_TEST_TMPDIR/out" scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -s "$BATS_TEST_TMPDIR/out/dependencies.sarif" ] || fail "no SARIF in SECURITY_DIR"
}

@test "findings (osv-scanner exit 1) do not fail the runner" {
  FAKE_EXIT=1 scan
  [ "$status" -eq 0 ] || fail "findings failed the runner: $status: $output"
  contains "$output" "dependencies: wrote" || fail "output: $output"
}

@test "an osv-scanner error (exit above 1) fails the runner" {
  FAKE_EXIT=2 scan
  [ "$status" -ne 0 ] || fail "an osv-scanner error passed: $output"
  not_contains "$output" "dependencies: wrote" || fail "reported a SARIF after an error: $output"
}

@test "switched off, it writes a skipped SARIF and never calls osv-scanner" {
  SECURITY_DEPENDENCIES=false scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note .security/dependencies.sarif)" disabled || fail "the SARIF does not say disabled"
  [ ! -s "$CALLS" ] || fail "osv-scanner ran: $(cat "$CALLS")"
}

@test "an invalid switch fails the runner, it does not skip it" {
  SECURITY_DEPENDENCIES=yes scan
  [ "$status" -ne 0 ] || fail "an invalid switch passed: $output"
  contains "$output" SECURITY_DEPENDENCIES || fail "the error does not name the variable: $output"
  [ ! -e .security ] || fail "an invalid switch wrote a SARIF"
}

@test "without osv-scanner it skips locally" {
  PATH="$(bare_path)" run bash "$REPO_ROOT/scripts/security/dependencies.sh"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note .security/dependencies.sarif)" "osv-scanner is not installed" || fail "wrong skip note"
}

@test "without osv-scanner it fails under CI" {
  CI=true PATH="$(bare_path)" run bash "$REPO_ROOT/scripts/security/dependencies.sh"
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "osv-scanner is not installed" || fail "output: $output"
  [ ! -e .security/dependencies.sarif ] || fail "a CI failure wrote a skipped SARIF"
}
