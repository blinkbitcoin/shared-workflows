#!/usr/bin/env bats
# scripts/security/scan.sh - the local all-jobs loop: runs every security
# runner beside it (or only the jobs named), then the verdict over this run's
# SARIF, and exits with the verdict's code.
#
# Covers every way out of it: the master switch off (exit 0, nothing run), an
# invalid SECURITY_ENABLED or settings file (fails, never reads as disabled),
# an unknown job (exit 2), named jobs only, every job (each skipping locally
# for want of its tool, or off by default), a runner that fails (the loop
# stops), stale SARIF from an earlier run removed, and the verdict's failing
# exit code handed back. It is called by a relative path from another
# directory, since it has to find its runners before runner.sh moves into the
# consumer.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY GITHUB_ACTIONS ANDROID_HOME ANDROID_SDK_ROOT APK IPA
  # shellcheck disable=SC2046  # one name per word
  unset $(compgen -e | grep '^SECURITY_' || true)
  mkdir -p "$BATS_TEST_TMPDIR/consumer"
  cd "$BATS_TEST_TMPDIR/consumer" || return 1
  consumer="$(pwd -P)"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'pnpm %s\n' "$*" >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
components="${FAKE_COMPONENTS:-}"
[ -n "$components" ] || components='[{}]'
printf '{"bomFormat":"CycloneDX","components":%s}' "$components" > "$out"
STUB
  chmod +x "$bin/pnpm"
}

compliant_workspace() {
  printf 'minimumReleaseAge: 1440\nstrictDepBuilds: true\ntrustPolicy: no-downgrade\n' > pnpm-workspace.yaml
}

# A PATH with node and the basics the runners need, and no scanner, so every
# tool-driven job skips locally even on a machine that has the tools.
bare_path() {
  local bare="$BATS_TEST_TMPDIR/bare-bin" tool
  mkdir -p "$bare"
  for tool in node bash env dirname basename mkdir cat grep sed find sort head tail rm tr; do
    ln -sf "$(command -v "$tool")" "$bare/$tool"
  done
  printf '%s' "$bare"
}

scan() { PATH="$bin:$PATH" run bash "$REPO_ROOT/scripts/security/scan.sh" "$@"; }

@test "SECURITY_ENABLED=false runs nothing and exits 0" {
  SECURITY_ENABLED=false scan
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "security scanning is disabled" || fail "output: $output"
  not_contains "$output" "security: " || fail "a verdict ran: $output"
  [ ! -e .security ] || fail "the switched-off run made .security"
  [ ! -s "$CALLS" ] || fail "a scanner ran: $(cat "$CALLS")"
}

@test "an invalid SECURITY_ENABLED fails the run, it does not read as disabled" {
  SECURITY_ENABLED=maybe scan
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" SECURITY_ENABLED || fail "the error does not name the variable: $output"
  contains "$output" "failed resolving enabled" || fail "the script's own message is missing: $output"
  not_contains "$output" "security scanning is disabled" || fail "read as disabled: $output"
}

@test "any invalid SECURITY_* value fails the run, it does not read as disabled" {
  SECURITY_SEVERITY=nonsense scan
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" SECURITY_SEVERITY || fail "the error does not name the variable: $output"
  not_contains "$output" "disabled" || fail "read as disabled: $output"
}

@test "a malformed security-settings.json fails the run, it does not read as disabled" {
  printf '{ this is not valid json' > "$BATS_TEST_TMPDIR/security-settings.json"
  SECURITY_SETTINGS_FILE="$BATS_TEST_TMPDIR/security-settings.json" scan
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" JSON || fail "the parse error is missing: $output"
  not_contains "$output" "security scanning is disabled" || fail "read as disabled: $output"
}

@test "an unknown job exits 2 before anything runs" {
  scan sbom lint
  [ "$status" -eq 2 ] || fail "expected 2, got $status: $output"
  contains "$output" "unknown security job: lint" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "a scanner ran: $(cat "$CALLS")"
}

@test "named jobs run alone, then their own verdict" {
  compliant_workspace
  scan sbom policy
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "sbom: clean" || fail "output: $output"
  contains "$output" "policy: clean" || fail "output: $output"
  contains "$output" "security: pass, highest none, 0 finding(s)" || fail "output: $output"
  [ -e .security/sbom.sarif ] || fail "sbom did not run"
  [ ! -e .security/dependencies.sarif ] || fail "a job that was not named ran"
}

@test "with no job named every runner runs, each skipping locally what it cannot do" {
  compliant_workspace
  PATH="$(bare_path)" run bash "$REPO_ROOT/scripts/security/scan.sh"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  local job
  for job in dependencies code policy sbom bundle mobile binaries review review-codebase; do
    [ -s ".security/$job.sarif" ] || fail "$job wrote no SARIF: $output"
  done
  contains "$output" "dependencies: skipped" || fail "output: $output"
  contains "$output" "review-codebase: skipped" || fail "output: $output"
  contains "$output" "policy: clean" || fail "output: $output"
  contains "$output" "security: skipped, highest none, 0 finding(s), 0 suppressed, 8 job(s) skipped" || fail "verdict: $output"
}

@test "a runner that fails stops the loop before the verdict" {
  FAKE_COMPONENTS='[]' scan sbom policy
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "no components" || fail "output: $output"
  [ ! -e .security/policy.sarif ] || fail "the loop ran on after a failed runner"
  not_contains "$output" "security: " || fail "a verdict ran: $output"
}

@test "SARIF from an earlier run is removed before this one" {
  compliant_workspace
  mkdir -p .security
  printf 'not even JSON' > .security/bundle.sarif
  scan policy
  [ "$status" -eq 0 ] || fail "a stale SARIF reached the verdict: $status: $output"
  [ ! -e .security/bundle.sarif ] || fail "the stale SARIF is still there"
  not_contains "$output" "bundle" || fail "the verdict judged the stale file: $output"
}

@test "the verdict's failing exit code is handed back" {
  printf 'trustPolicy: no-downgrade\n' > pnpm-workspace.yaml
  scan policy
  [ "$status" -eq 1 ] || fail "expected the verdict's 1, got $status: $output"
  contains "$output" "security: fail" || fail "output: $output"
}

@test "called by a relative path from another directory, under GITHUB_WORKSPACE" {
  compliant_workspace
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  cd "$BATS_TEST_TMPDIR/elsewhere" || fail "no elsewhere"
  local relative
  relative="$(node -e 'console.log(require("path").relative(process.cwd(), process.argv[1]))' "$REPO_ROOT/scripts/security/scan.sh")"
  case "$relative" in /*) fail "not a relative path: $relative" ;; esac
  GITHUB_WORKSPACE="$consumer" PATH="$bin:$PATH" run bash "$relative" sbom policy
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -e "$consumer/.security/sbom.sarif" ] || fail "the runners did not write into the consumer"
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere/.security" ] || fail "wrote into the calling directory"
}
