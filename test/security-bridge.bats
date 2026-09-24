#!/usr/bin/env bats
# The four bridges check-security.yml runs. Everything they bridge *to* - the
# resolver, the runners, the merge - lives in the consumer, and none of it is
# reimplemented here. What is tested is the seam: that a consumer missing one of
# those files fails loudly and by name, and that a runner which reports nothing
# can never be read as a runner which found nothing.
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

@test "settings.sh publishes enabled, severity, failOn and one output per job" {
  local consumer
  consumer="$(consumer_with on scripts/security/config.mjs <<'EOF'
console.log(
  JSON.stringify({
    enabled: true,
    jobs: { deps: true, code: false, policy: true },
    severity: 'high',
    failOn: ['deterministic'],
  }),
);
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  local written
  written="$(cat "$GITHUB_OUTPUT")"
  local want
  for want in 'enabled=true' 'severity=high' 'fail-on=deterministic' 'deps=true' 'code=false' 'policy=true'; do
    grep -qxF "$want" <<<"$written" || fail "no '$want' among the published outputs: $written"
  done
}

@test "settings.sh fails by name when the consumer ships no resolver" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/config.mjs' || fail "the error does not name the missing file: $output"
  contains "$output" '::error::' || fail "the failure is not a GitHub annotation: $output"
}

# The failure mode worth a test of its own: config.mjs guards its CLI entry with
# `import.meta.main`, undefined before Node 24. An older node runs the file,
# prints nothing, exits 0 - and empty output read as "no jobs enabled" would
# disable the whole gate in silence.
@test "settings.sh treats a resolver that prints nothing as fatal, not as all-off" {
  local consumer
  consumer="$(consumer_with silent scripts/security/config.mjs <<'EOF'
// prints nothing, exits 0
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "an empty resolver read as a valid answer: $output"
  contains "$output" 'Node 24' || fail "the error does not name the cause: $output"
}

@test "settings.sh rejects output that is not the settings object" {
  local consumer
  consumer="$(consumer_with broken scripts/security/config.mjs <<'EOF'
console.log('not the settings object at all');
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "unreadable output was read as a valid answer: $output"
  contains "$output" 'not the settings object' || fail "the error does not say what was wrong: $output"
}

@test "run-job.sh runs the consumer's runner and reports where the SARIF landed" {
  local consumer
  consumer="$(consumer_with good scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${SECURITY_DIR:-.security}"
mkdir -p "$out"
printf '{"version":"2.1.0","runs":[]}' > "$out/deps.sarif"
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  [ -s "$consumer/.security/deps.sarif" ] || fail "no SARIF at $consumer/.security/deps.sarif"
}

@test "run-job.sh fails by name when the consumer ships no runner for the job" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/norunner"
  mkdir -p "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" code
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/code.sh' || fail "the error does not name the missing runner: $output"
  contains "$output" 'security-policy.json' || fail "the error does not say how to switch the job off: $output"
}

# A runner that exits 0 without writing its SARIF would reach the verdict as
# nothing at all, and the verdict cannot tell "found nothing" from "reported
# nothing". So the bridge insists on the file.
@test "run-job.sh fails when a runner exits 0 having reported nothing" {
  local consumer
  consumer="$(consumer_with quiet scripts/security/policy.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 1 ] || fail "a silent runner passed: $output"
  contains "$output" 'policy.sarif' || fail "the error does not name the SARIF that is missing: $output"
}

@test "run-job.sh hands back a crashing runner's exit code" {
  local consumer
  consumer="$(consumer_with crash scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
echo "osv-scanner: bad config" >&2
exit 3
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 3 ] || fail "expected the runner's own exit code 3, got $status: $output"
}

@test "verdict.sh runs the consumer's merge, prints it, and keeps its exit code" {
  local consumer
  consumer="$(consumer_with fails scripts/security/verdict.mjs <<'EOF'
console.log('deps: 1 finding(s), highest high');
console.log('security: fail, highest high, 1 finding(s), 0 suppressed, 0 job(s) skipped');
process.exit(1);
EOF
)"
  mkdir -p "$consumer/.security"
  printf '{"version":"2.1.0","runs":[]}' > "$consumer/.security/deps.sarif"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "the verdict's exit code was not handed back: $status / $output"
  contains "$output" 'security: fail' || fail "the report never reached the log: $output"
  grep -q 'security: fail' "$BATS_TEST_TMPDIR/summary.md" || fail "the report never reached the run summary"
  grep -q '^## Security' "$BATS_TEST_TMPDIR/summary.md" || fail "the summary block has no heading"
}

@test "verdict.sh refuses to report a clean run when no scanner reported at all" {
  local consumer
  consumer="$(consumer_with empty scripts/security/verdict.mjs <<'EOF'
console.log('security: pass');
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "an empty .security/ produced a verdict: $output"
  contains "$output" 'no SARIF files' || fail "the error does not say what was missing: $output"
}

@test "verdict.sh fails by name when the consumer ships no merge" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/nomerge"
  mkdir -p "$GITHUB_WORKSPACE/.security"
  printf '{}' > "$GITHUB_WORKSPACE/.security/deps.sarif"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/verdict.mjs' || fail "the error does not name the missing file: $output"
}

@test "sarif-upload-skipped.sh warns in the log and in the summary, with the reason" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh" "this run is a pull request from a fork"
  [ "$status" -eq 0 ] || fail "$output"
  contains "$output" '::warning::' || fail "a missing upload passed without an annotation: $output"
  contains "$output" 'pull request from a fork' || fail "the reason is missing: $output"
  grep -q 'not.*uploaded to code scanning' "$BATS_TEST_TMPDIR/summary.md" \
    || fail "the run summary does not say the findings never reached code scanning"
  grep -q 'still applied the threshold' "$BATS_TEST_TMPDIR/summary.md" \
    || fail "the run summary does not say the gate still ran"
}

@test "sarif-upload-skipped.sh refuses to run without a reason" {
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh"
  [ "$status" -ne 0 ] || fail "a reasonless notice is exactly the silence this step exists to prevent: $output"
}

# ---------------------------------------------------------------------------
# binaries-fetch.sh - the one bridge that talks to GitHub rather than to the
# consumer. A fake gh stands in: `release view` succeeds for any tag but
# v-missing; `release download` writes whatever $FAKE_ASSETS names into --dir,
# or fails the way the real gh does for no match ($FAKE_NO_ASSETS) or for a
# broken download ($FAKE_BROKEN). Every call is recorded.
# ---------------------------------------------------------------------------

fake_gh() {
  local bin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$BATS_TEST_TMPDIR/gh-calls"
if [ "$1 $2" = "release view" ]; then
  [ "$3" != v-missing ] || { echo "release not found" >&2; exit 1; }
  exit 0
fi
if [ "$1 $2" = "release download" ]; then
  [ -z "${FAKE_BROKEN:-}" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
  [ -z "${FAKE_NO_ASSETS:-}" ] || { echo "$FAKE_NO_ASSETS" >&2; exit 1; }
  dir=""
  while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir="$2"; shift; done
  for asset in ${FAKE_ASSETS:-}; do : > "$dir/$asset"; done
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 2
GH
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github-env"
  : > "$GITHUB_ENV"
}

@test "binaries-fetch.sh downloads the three binary types and hands their directory on" {
  fake_gh
  export FAKE_ASSETS="app-release.aab app-universal.apk"
  run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" v1.2.3 "$BATS_TEST_TMPDIR/bin-out"
  [ "$status" -eq 0 ] || fail "binaries-fetch.sh failed: $output"
  calls="$(cat "$BATS_TEST_TMPDIR/gh-calls")"
  contains "$calls" "--pattern *.apk --pattern *.aab --pattern *.ipa" \
    || fail "the download did not ask for all three binary types: $calls"
  contains "$output" "2 file(s) from v1.2.3" || fail "the log does not count what arrived: $output"
  grep -qxF "SECURITY_BINARIES_DIR=$(cd "$BATS_TEST_TMPDIR/bin-out" && pwd -P)" "$GITHUB_ENV" \
    || fail "SECURITY_BINARIES_DIR was not published: $(cat "$GITHUB_ENV")"
}

@test "binaries-fetch.sh without a tag fails, naming both ways out" {
  fake_gh
  run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" "" "$BATS_TEST_TMPDIR/bin-out"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" "release-tag" || fail "the error does not name the input to pass: $output"
  contains "$output" "binaries: false" || fail "the error does not name the switch: $output"
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ] || fail "gh was called with no tag: $(cat "$BATS_TEST_TMPDIR/gh-calls")"
}

@test "binaries-fetch.sh fails when the release does not exist" {
  fake_gh
  run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" v-missing "$BATS_TEST_TMPDIR/bin-out"
  [ "$status" -eq 1 ] || fail "a missing release did not fail: $output"
  contains "$output" "release v-missing was not found" || fail "the error does not name the release: $output"
}

@test "binaries-fetch.sh treats a release with no binaries as a notice, in either of gh's wordings" {
  fake_gh
  for wording in "no assets to download" "no assets match the file pattern"; do
    export FAKE_NO_ASSETS="$wording"
    run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" v1.2.3 "$BATS_TEST_TMPDIR/empty-$RANDOM"
    [ "$status" -eq 0 ] || fail "'$wording' failed the step: $output"
    contains "$output" "::notice::release v1.2.3 carries no .apk, .aab or .ipa" \
      || fail "'$wording' was not reported as a notice: $output"
  done
  grep -q '^SECURITY_BINARIES_DIR=' "$GITHUB_ENV" \
    || fail "an empty release still has to hand the runner its (empty) directory: $(cat "$GITHUB_ENV")"
}

@test "binaries-fetch.sh fails when the download itself breaks, rather than reading it as empty" {
  fake_gh
  export FAKE_BROKEN=1
  run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" v1.2.3 "$BATS_TEST_TMPDIR/bin-out"
  [ "$status" -eq 1 ] || fail "a broken download passed: $output"
  contains "$output" "HTTP 502" || fail "the error does not carry gh's own message: $output"
}
