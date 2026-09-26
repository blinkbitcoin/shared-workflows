#!/usr/bin/env bats
# The seam between the bridges check-security.yml runs. Each bridge has its own
# test file, named after it (settings.bats, run-job.bats, verdict.bats,
# sarif-upload-skipped.bats, binaries-fetch.bats), which covers every way out of
# that one script. What stays here is what no single script's file can show:
# that the bridges agree with each other - that the SARIF run-job.sh insists on
# is the SARIF verdict.sh reads. Everything they bridge *to* - the resolver, the
# runners, the merge - lives in the consumer, and none of it is reimplemented
# here.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# A throwaway consumer checkout. $1 names the directory; the script's body is
# read from stdin so a test can hand it any behaviour, including no output at
# all. Nothing is copied from the template: these are stand-ins for the
# consumer's files, not second copies of them.
consumer_with() {
  local dir="$BATS_TEST_TMPDIR/$1" file="$2"
  mkdir -p "$dir/$(dirname "$file")"
  cat > "$dir/$file"
  printf '%s' "$dir"
}

@test "the SARIF run-job.sh insists on is the SARIF verdict.sh merges" {
  local consumer
  consumer="$(consumer_with chain scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"version":"2.1.0","runs":[]}' > "${SECURITY_DIR:-.security}/deps.sarif"
EOF
)"
  consumer_with chain scripts/security/verdict.mjs > /dev/null <<'EOF'
import { readdirSync } from 'node:fs';
console.log(`merged: ${readdirSync(process.argv[2]).join(' ')}`);
EOF
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 0 ] || fail "verdict.sh failed on what run-job.sh accepted: $output"
  contains "$output" 'merged: deps.sarif' || fail "the merge did not see the runner's SARIF: $output"
}
