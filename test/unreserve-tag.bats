#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/release/unreserve-tag.sh: deletes the build tag reserve-tag.sh
# created, when the release that reserved it fails. It *deletes a git tag*, so
# the exact API path is asserted, and every way it can refuse is pinned: no
# tag, no GH_REPO, no gh, and a delete the API rejects. It has no `die` site of
# its own, which is unusual enough in this repository to be worth pinning
# deliberately rather than leaving implicit.
#
# `gh` is stubbed: each call appends its arguments to a log, and a DELETE
# succeeds unless WORKFLOWS_TEST_FAIL is set. No network.

load test_helper

UNRESERVE="$REPO_ROOT/scripts/release/unreserve-tag.sh"

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

@test "unreserve deletes exactly the ref it was given" {
  # The assertion that matters: the path, in full. A tag deleted by a wrong
  # path is either a no-op or someone else's tag.
  run bash "$UNRESERVE" v1.2.3-build.42
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "-X DELETE repos/acme/app/git/refs/tags/v1.2.3-build.42" \
    || fail "wrong delete call: $output"
}

@test "unreserve deletes one ref and nothing else" {
  run bash "$UNRESERVE" v1.2.3-build.42
  run cat "$CALLS"
  [ "$(grep -c . <<< "$output")" -eq 1 ] || fail "expected exactly one gh call: $output"
  not_contains "$output" "-X POST" || fail "a delete must not create anything: $output"
}

@test "unreserve needs a tag and GH_REPO, and names what is missing" {
  run bash "$UNRESERVE"
  [ "$status" -ne 0 ] || fail "no tag must be a usage error"
  contains "$output" "usage" || fail "does not say how to call it: $output"
  run cat "$CALLS"
  [ ! -s "$CALLS" ] || fail "it called gh without a tag: $output"

  GH_REPO="" run bash "$UNRESERVE" v1.2.3-build.42
  [ "$status" -ne 0 ] || fail "an empty GH_REPO must be refused"
  contains "$output" "GH_REPO" || fail "does not name the missing variable: $output"
}

@test "a failed delete is fatal rather than a silent success" {
  # It runs under `if: failure()`, so its own failure is easy to miss - but a
  # tag left behind names a commit that has no release, and the next run of the
  # same version then refuses to build. Loud is right.
  WORKFLOWS_TEST_FAIL="Not Found" run bash "$UNRESERVE" v1.2.3-build.42
  [ "$status" -ne 0 ] || fail "a failed delete must not report success: $output"
}

@test "a deleted tag is named in the log, and nothing is written to the step outputs" {
  run bash "$UNRESERVE" v1.2.3-build.42
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "deleted tag v1.2.3-build.42" || fail "the log does not name the tag: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "unreserve wrote step outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "a failed delete does not claim to have deleted anything" {
  WORKFLOWS_TEST_FAIL="HTTP 422: Reference does not exist" run bash "$UNRESERVE" v1.2.3-build.42
  [ "$status" -ne 0 ] || fail "a failed delete must not report success: $output"
  contains "$output" "Reference does not exist" || fail "the API's reason is not shown: $output"
  not_contains "$output" "deleted tag" || fail "it logged a delete that did not happen: $output"
}

@test "a runner without gh is refused before anything else happens" {
  # Only the tools the script needs before its gh check: dirname to find
  # common.sh. gh, the stub included, is deliberately absent.
  local only="$BATS_TEST_TMPDIR/only"
  mkdir -p "$only"
  ln -s "$(command -v dirname)" "$only/dirname"
  run env PATH="$only" "$BASH" "$UNRESERVE" v1.2.3-build.42
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: gh" || fail "does not name the missing command: $output"
  [ ! -s "$CALLS" ] || fail "gh was called: $(cat "$CALLS")"
}
