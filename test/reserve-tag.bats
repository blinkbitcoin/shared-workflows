#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# reserve-tag.sh decides which commit a released version names: it creates a
# permanent, public name for a commit. It and unreserve-tag.sh, which removes
# that name again, once had no test of any kind - the highest-risk gap in the
# repository. unreserve-tag.sh's own cases are in unreserve-tag.bats; the last
# case here is about the pair, as the workflow wires them.
#
# `gh` is stubbed: each call appends its arguments to a log, and the response
# comes from a canned file. No network, and the exact API path is asserted -
# a tag created at the wrong ref is the failure that matters here.

load test_helper

RESERVE="$REPO_ROOT/scripts/release/reserve-tag.sh"

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  # GET answers from a file; POST/DELETE succeed unless WORKFLOWS_TEST_FAIL is set.
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
case "$*" in
  *"-X DELETE"*|*"-X POST"*)
    if [ -n "${WORKFLOWS_TEST_FAIL:-}" ]; then
      printf '%s\n' "$WORKFLOWS_TEST_FAIL" >&2
      exit 1
    fi
    exit 0
    ;;
esac
# A GET: print the canned existing sha, or fail like gh does on a 404.
if [ -s "$WORKFLOWS_TEST_EXISTING" ]; then
  cat "$WORKFLOWS_TEST_EXISTING"
  exit 0
fi
printf 'gh: Not Found (HTTP 404)\n' >&2
exit 1
SH
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH"
  EXISTING="$BATS_TEST_TMPDIR/existing"
  : > "$EXISTING"
  export WORKFLOWS_TEST_CALLS="$CALLS" WORKFLOWS_TEST_EXISTING="$EXISTING"
  export GH_REPO="acme/app"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : > "$GITHUB_OUTPUT"
  export GITHUB_OUTPUT
}

# --- reserve -------------------------------------------------------------

@test "reserve creates the tag at the sha and reports that it reserved one" {
  run bash "$RESERVE" v1.2.3-build.42 deadbeef
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "-X POST repos/acme/app/git/refs" || fail "wrong create call: $output"
  contains "$output" "ref=refs/tags/v1.2.3-build.42" || fail "wrong ref: $output"
  contains "$output" "sha=deadbeef" || fail "wrong sha: $output"
  run cat "$GITHUB_OUTPUT"
  contains "$output" "reserved=true" || fail "did not report reserving: $output"
}

@test "a tag already at the same sha is a no-op, and reports it did not reserve" {
  # The re-run case. Reporting `reserved=false` is what stops the failure path
  # deleting a tag this run did not create.
  printf 'deadbeef\n' > "$EXISTING"
  run bash "$RESERVE" v1.2.3-build.42 deadbeef
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "already points at" || fail "$output"
  run cat "$GITHUB_OUTPUT"
  contains "$output" "reserved=false" || fail "a re-run must not claim to have reserved: $output"
  run cat "$CALLS"
  not_contains "$output" "-X POST" || fail "it created a tag that already existed: $output"
}

@test "a tag at a different sha is fatal, and says both shas" {
  # Building under a tag that names another commit is the failure this guards.
  printf 'cafe1234\n' > "$EXISTING"
  run bash "$RESERVE" v1.2.3-build.42 deadbeef
  [ "$status" -ne 0 ] || fail "must refuse a tag pointing elsewhere"
  contains "$output" "cafe1234" || fail "does not name the existing sha: $output"
  contains "$output" "deadbeef" || fail "does not name the wanted sha: $output"
}

@test "a refused create explains the GITHUB_TOKEN workflow rule" {
  # The 403 that broke pre-releases: GITHUB_TOKEN may not tag a commit whose
  # .github/workflows differ from the default branch tip.
  WORKFLOWS_TEST_FAIL="Resource not accessible by integration" \
    run bash "$RESERVE" v1.2.3-build.42 deadbeef
  [ "$status" -ne 0 ] || fail "a failed create must be fatal"
  contains "$output" "Resource not accessible by integration" || fail "$output"
  contains "$output" "workflows" || fail "does not explain the rule: $output"
}

@test "reserve needs both arguments and GH_REPO" {
  run bash "$RESERVE"
  [ "$status" -ne 0 ] || fail "no arguments must be a usage error"
  run bash "$RESERVE" v1.2.3-build.42
  [ "$status" -ne 0 ] || fail "a missing sha must be a usage error"
  GH_REPO="" run bash "$RESERVE" v1.2.3-build.42 deadbeef
  [ "$status" -ne 0 ] || fail "an empty GH_REPO must be refused"
}

# --- the pair, and the workflow that wires them -------------------------

@test "the failure path only deletes a tag the same run reserved" {
  # reserve-tag.sh writes `reserved=false` on the re-run path precisely so this
  # condition is false. If the guard were dropped, a re-run that found its tag
  # already in place would delete a tag it did not create.
  run node -e '
    const text = require("fs").readFileSync(`${process.env.REPO_ROOT}/.github/workflows/build-prepare.yml`, "utf8");
    const step = text.split("unreserve-tag.sh")[0];
    const guard = step.slice(step.lastIndexOf("- name:"));
    if (!/failure\(\)/.test(guard)) throw new Error("the unreserve step is not gated on failure()");
    if (!/steps\.reserve\.outputs\.reserved == .true./.test(guard)) {
      throw new Error("the unreserve step no longer checks that this run reserved the tag");
    }
  '
  [ "$status" -eq 0 ] || fail "$output"
}
