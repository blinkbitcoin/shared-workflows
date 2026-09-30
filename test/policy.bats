#!/usr/bin/env bats
# scripts/security/policy.sh - asserts the pnpm install policy in
# pnpm-workspace.yaml (or SECURITY_POLICY_TARGET_FILE): minimumReleaseAge set,
# strictDepBuilds true, trustPolicy no-downgrade. Each rule that does not hold
# is a finding in <SECURITY_DIR>/policy.sarif; findings never fail the runner.
#
# Covers every way out of it: a compliant file (a clean SARIF, comments
# allowed), each of the three rules failing on its own, near-miss values, the
# target file override, a missing file (all three fail), and the job switched
# off.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY GITHUB_ACTIONS
  # shellcheck disable=SC2046  # one name per word
  unset $(compgen -e | grep '^SECURITY_' || true)
  mkdir -p "$BATS_TEST_TMPDIR/consumer"
  cd "$BATS_TEST_TMPDIR/consumer" || return 1
}

# The rule identifiers of the SARIF's findings, space-separated and sorted.
rules() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(d.runs[0].results.map((r) => r.ruleId).sort().join(" "))' "${1:-.security/policy.sarif}"
}

compliant() {
  cat <<'EOF'
packages:
  - .
minimumReleaseAge: 1440 # a day
strictDepBuilds: true
trustPolicy: no-downgrade
EOF
}

policy() { run bash "$REPO_ROOT/scripts/security/policy.sh"; }

@test "a compliant pnpm-workspace.yaml gives a clean SARIF" {
  compliant > pnpm-workspace.yaml
  policy
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -z "$(rules)" ] || fail "findings on a compliant file: $(rules)"
  node -e 'const d = JSON.parse(require("fs").readFileSync(".security/policy.sarif", "utf8"));
    process.exit(d.runs[0].invocations[0].executionSuccessful === true ? 0 : 1)' ||
    fail "the run is not marked successful"
  contains "$output" "policy: wrote .security/policy.sarif" || fail "output: $output"
}

@test "a missing minimumReleaseAge is a finding" {
  compliant | grep -v minimumReleaseAge > pnpm-workspace.yaml
  policy
  [ "$status" -eq 0 ] || fail "a finding failed the runner: $status: $output"
  [ "$(rules)" = "pnpm/minimum-release-age" ] || fail "rules: $(rules)"
}

@test "a strictDepBuilds that is not true is a finding" {
  compliant | sed 's/^strictDepBuilds: true/strictDepBuilds: false/' > pnpm-workspace.yaml
  policy
  [ "$status" -eq 0 ] || fail "a finding failed the runner: $status: $output"
  [ "$(rules)" = "pnpm/strict-dep-builds" ] || fail "rules: $(rules)"
}

@test "a missing trustPolicy is a finding" {
  compliant | grep -v trustPolicy > pnpm-workspace.yaml
  policy
  [ "$status" -eq 0 ] || fail "a finding failed the runner: $status: $output"
  [ "$(rules)" = "pnpm/trust-policy" ] || fail "rules: $(rules)"
}

@test "near-miss values are findings, not just missing keys" {
  cat > pnpm-workspace.yaml <<'EOF'
minimumReleaseAge: 0
strictDepBuilds: truee
trustPolicy: no-downgrade-x
EOF
  policy
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(rules)" = "pnpm/minimum-release-age pnpm/strict-dep-builds pnpm/trust-policy" ] || fail "rules: $(rules)"
}

@test "SECURITY_POLICY_TARGET_FILE names the file to check" {
  compliant > pnpm-workspace.yaml
  printf 'strictDepBuilds: true\n' > "$BATS_TEST_TMPDIR/other.yaml"
  SECURITY_POLICY_TARGET_FILE="$BATS_TEST_TMPDIR/other.yaml" policy
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(rules)" = "pnpm/minimum-release-age pnpm/trust-policy" ] || fail "the override was not read: $(rules)"
}

@test "a missing file fails every rule" {
  SECURITY_POLICY_TARGET_FILE=/dev/null policy
  [ "$(rules)" = "pnpm/minimum-release-age pnpm/strict-dep-builds pnpm/trust-policy" ] || fail "/dev/null: $(rules)"
  rm -rf .security
  policy
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(rules)" = "pnpm/minimum-release-age pnpm/strict-dep-builds pnpm/trust-policy" ] || fail "no file: $(rules)"
}

@test "switched off, it writes a skipped SARIF" {
  SECURITY_POLICY=false policy
  [ "$status" -eq 0 ] || fail "status $status: $output"
  node -e 'const d = JSON.parse(require("fs").readFileSync(".security/policy.sarif", "utf8"));
    process.exit(/disabled/.test(d.runs[0].invocations[0].toolExecutionNotifications[0].message.text) ? 0 : 1)' ||
    fail "the SARIF does not say disabled"
}
