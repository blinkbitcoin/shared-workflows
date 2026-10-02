#!/usr/bin/env bats
# scripts/security/code.sh - Semgrep over the app source with the community
# TypeScript, secrets and OWASP packs, plus every path jobs.code.rules names in
# security-settings.json, into <SECURITY_DIR>/code.sarif.
#
# Covers every way out of it: the three packs and the family's own rules alone, rules added from the
# settings file and from SECURITY_CODE_RULES, a named rules path that does not
# exist (fails naming it), an invalid rules setting, a Semgrep error, the job
# switched off, and Semgrep missing - a skip locally, a failure under CI.
# semgrep is a fake on PATH that records its arguments, one per line.
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
  cat > "$bin/semgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CALLS"
if [ "$1" = --test ]; then exit "${FAKE_TEST_EXIT:-0}"; fi
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
printf '{"version":"2.1.0","runs":[]}' > "$out"
exit "${FAKE_EXIT:-0}"
STUB
  chmod +x "$bin/semgrep"
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

# The --config values semgrep was given, space-separated.
configs() { awk 'prev == "--config" { printf "%s ", $0 } { prev = $0 }' "$CALLS"; }

scan() { PATH="$bin:$PATH" run bash "$REPO_ROOT/scripts/security/code.sh"; }

@test "with no rules of its own it runs the three community packs and the family rules into code.sarif" {
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(configs)" = "p/typescript p/secrets p/owasp-top-ten $REPO_ROOT/scripts/security/rules " ] || fail "configs: $(configs)"
  [ "$(head -1 "$CALLS")" = scan ] || fail "not semgrep scan: $(cat "$CALLS")"
  grep -qxF -- --sarif "$CALLS" || fail "no --sarif: $(cat "$CALLS")"
  grep -qxF .security/code.sarif "$CALLS" || fail "not written to .security/code.sarif: $(cat "$CALLS")"
  grep -A1 -xF -- --metrics "$CALLS" | grep -qxF off || fail "metrics not off: $(cat "$CALLS")"
  [ -s .security/code.sarif ] || fail "no SARIF"
  contains "$output" "code: wrote .security/code.sarif" || fail "output: $output"
}

# One --exclude value per line of semgrepignore, comments and blanks skipped.
excludes() { awk 'prev == "--exclude" { printf "%s ", $0 } { prev = $0 }' "$CALLS"; }

@test "it passes the family's ignore list as --exclude, comments and blank lines skipped" {
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(excludes)" = "node_modules/ ios/ android/ dist/ coverage/ vendor/bundle/ .expo/ .claude/worktrees/ .workflows/ " ] || fail "excludes: $(excludes)"
}

@test "a repository's own .semgrepignore does not replace the family's list" {
  printf 'src/generated/\n' > .semgrepignore
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(excludes)" "node_modules/" || fail "the family's list is gone: $(excludes)"
}

@test "it finds its rules and ignore list when run by a relative path from elsewhere" {
  cd "$REPO_ROOT" || return 1
  PATH="$bin:$PATH" run bash scripts/security/code.sh
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(configs)" = "p/typescript p/secrets p/owasp-top-ten $REPO_ROOT/scripts/security/rules " ] || fail "configs: $(configs)"
  rm -rf "$REPO_ROOT/.security"
}

@test "jobs.code.rules in security-settings.json adds one --config per path" {
  mkdir -p semgrep/rules
  : > semgrep/app.yml
  printf '{"jobs":{"code":{"rules":["semgrep/app.yml","semgrep/rules"]}}}' > security-settings.json
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(configs)" = "p/typescript p/secrets p/owasp-top-ten $REPO_ROOT/scripts/security/rules semgrep/app.yml semgrep/rules " ] || fail "configs: $(configs)"
}

# The calls semgrep got for rule tests: each `--test` invocation's last argument.
tested() { grep -A3 -xF -- --test "$CALLS" | awk 'NR % 4 == 0'; }

@test "a rules directory has its own rule tests run before the scan, a rules file does not" {
  mkdir -p semgrep/rules
  : > semgrep/app.yml
  printf '{"jobs":{"code":{"rules":["semgrep/app.yml","semgrep/rules"]}}}' > security-settings.json
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(grep -cxF -- --test "$CALLS")" = 1 ] || fail "wrong number of rule test runs: $(cat "$CALLS")"
  [ "$(tested)" = semgrep/rules ] || fail "tested: $(tested)"
  [ "$(grep -nxF -- --test "$CALLS" | cut -d: -f1)" -lt "$(grep -nxF scan "$CALLS" | cut -d: -f1)" ] || fail "tests ran after the scan"
}

@test "a failing rule test fails the run naming the directory, and nothing is scanned" {
  mkdir -p semgrep/rules
  printf '{"jobs":{"code":{"rules":["semgrep/rules"]}}}' > security-settings.json
  FAKE_TEST_EXIT=1 scan
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "code: the rule tests in semgrep/rules failed" || fail "output: $output"
  ! grep -qxF scan "$CALLS" || fail "the scan ran anyway: $(cat "$CALLS")"
}

@test "with no rules of its own there are no rule tests" {
  scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  ! grep -qxF -- --test "$CALLS" || fail "rule tests ran: $(cat "$CALLS")"
}

@test "SECURITY_CODE_RULES wins over the settings file" {
  : > env.yml
  printf '{"jobs":{"code":{"rules":["missing.yml"]}}}' > security-settings.json
  SECURITY_CODE_RULES=env.yml scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(configs)" = "p/typescript p/secrets p/owasp-top-ten $REPO_ROOT/scripts/security/rules env.yml " ] || fail "configs: $(configs)"
}

@test "a rules path that does not exist fails the run naming it" {
  : > real.yml
  printf '{"jobs":{"code":{"rules":["real.yml","semgrep/typo.yml"]}}}' > security-settings.json
  scan
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "jobs.code.rules names semgrep/typo.yml, which does not exist" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "semgrep ran anyway: $(cat "$CALLS")"
}

# The resolver validates the whole file on every read, so an invalid rules
# value already fails at sec_enabled; sec_setting's own failure is covered in
# runner.bats.
@test "an invalid rules setting fails the run before semgrep" {
  printf '{"jobs":{"code":{"rules":5}}}' > security-settings.json
  scan
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "jobs.code.rules: expected a list, got 5" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "semgrep ran anyway: $(cat "$CALLS")"
}

@test "a Semgrep error fails the run" {
  FAKE_EXIT=2 scan
  [ "$status" -ne 0 ] || fail "a Semgrep error passed: $output"
  not_contains "$output" "code: wrote" || fail "reported a SARIF after an error: $output"
}

@test "switched off, it writes a skipped SARIF and never calls semgrep" {
  SECURITY_CODE=false scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note .security/code.sarif)" disabled || fail "the SARIF does not say disabled"
  [ ! -s "$CALLS" ] || fail "semgrep ran: $(cat "$CALLS")"
}

@test "without semgrep it skips locally" {
  PATH="$(bare_path)" run bash "$REPO_ROOT/scripts/security/code.sh"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note .security/code.sarif)" "semgrep is not installed" || fail "wrong skip note"
}

@test "without semgrep it fails under CI" {
  CI=true PATH="$(bare_path)" run bash "$REPO_ROOT/scripts/security/code.sh"
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "semgrep is not installed" || fail "output: $output"
  [ ! -e .security/code.sarif ] || fail "a CI failure wrote a skipped SARIF"
}
