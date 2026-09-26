#!/usr/bin/env bats
# scripts/security/label-sarif.sh - names every scanner's SARIF run after its
# job in check-security.yml before the upload, so code scanning lists
# "Dependencies" rather than "osv-scanner". Covers every way out of it: each
# job's file relabelled (every run in a file, and a file with no runs), the
# directory SECURITY_DIR names, a file no job leaves, a directory with no SARIF,
# and no jq.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

JOBS="deps code policy sbom bundle mobile binaries review openant"

sarif() {
  printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"%s","rules":[{"id":"r"}]}},"results":[{"ruleId":"r"}]}]}' "$1"
}

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$GITHUB_WORKSPACE/.security"
}

@test "label-sarif.sh names every job's runs after the job, and keeps the findings" {
  local job names
  for job in $JOBS; do
    sarif "tool-of-$job" > "$GITHUB_WORKSPACE/.security/$job.sarif"
  done
  run bash "$REPO_ROOT/scripts/security/label-sarif.sh"
  [ "$status" -eq 0 ] || fail "$output"
  names="$(for job in $JOBS; do jq -r '.runs[].tool.driver.name' "$GITHUB_WORKSPACE/.security/$job.sarif"; done | paste -sd, -)"
  [ "$names" = "Dependencies,Code,Policy,Bill of Materials,Bundle,Mobile,Binaries,Review,OpenAnt" ] \
    || fail "the runs are not named after the jobs: $names"
  [ "$(jq '.runs[0].results | length' "$GITHUB_WORKSPACE/.security/deps.sarif")" -eq 1 ] \
    || fail "labelling dropped the findings"
  [ "$(jq -r '.runs[0].tool.driver.rules[0].id' "$GITHUB_WORKSPACE/.security/deps.sarif")" = r ] \
    || fail "labelling dropped the rules code scanning reads severities from"
  ! ls "$GITHUB_WORKSPACE/.security/"*.labelled >/dev/null 2>&1 \
    || fail "a temporary file was left behind for upload-sarif to pick up"
}

@test "label-sarif.sh relabels every run in a file, and leaves a file with no runs valid" {
  printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"a"}}},{"tool":{"driver":{"name":"b"}}}]}' \
    > "$GITHUB_WORKSPACE/.security/code.sarif"
  printf '{"version":"2.1.0"}' > "$GITHUB_WORKSPACE/.security/policy.sarif"
  run bash "$REPO_ROOT/scripts/security/label-sarif.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(jq -r '[.runs[].tool.driver.name] | join(",")' "$GITHUB_WORKSPACE/.security/code.sarif")" = "Code,Code" ] \
    || fail "a second run kept its scanner's name"
  [ "$(jq -c '.runs' "$GITHUB_WORKSPACE/.security/policy.sarif")" = "[]" ] \
    || fail "a file with no runs was not left valid"
}

@test "label-sarif.sh reads the directory SECURITY_DIR names" {
  export SECURITY_DIR=reports
  mkdir -p "$GITHUB_WORKSPACE/reports"
  sarif osv-scanner > "$GITHUB_WORKSPACE/reports/deps.sarif"
  run bash "$REPO_ROOT/scripts/security/label-sarif.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(jq -r '.runs[0].tool.driver.name' "$GITHUB_WORKSPACE/reports/deps.sarif")" = Dependencies ] \
    || fail "SECURITY_DIR was not read"
}

@test "label-sarif.sh fails by name on a file no job leaves" {
  sarif stray > "$GITHUB_WORKSPACE/.security/stray.sarif"
  run bash "$REPO_ROOT/scripts/security/label-sarif.sh"
  [ "$status" -eq 1 ] || fail "an unknown job was uploaded under its scanner's own name: $output"
  contains "$output" '.security/stray.sarif' || fail "the error does not name the file: $output"
  contains "$output" 'no job named after stray' || fail "the error does not say why: $output"
}

@test "label-sarif.sh refuses a directory with no SARIF" {
  run bash "$REPO_ROOT/scripts/security/label-sarif.sh"
  [ "$status" -eq 1 ] || fail "labelling nothing passed: $output"
  contains "$output" '::error::no SARIF files in .security to label' \
    || fail "the error does not name the directory: $output"
}

@test "label-sarif.sh fails when jq is not on the PATH" {
  local bin="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bin"
  ln -sf "$(command -v dirname)" "$bin/dirname"
  run env PATH="$bin" "$BASH" "$REPO_ROOT/scripts/security/label-sarif.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: jq' || fail "the error does not name jq: $output"
}
