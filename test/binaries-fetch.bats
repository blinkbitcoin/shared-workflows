#!/usr/bin/env bats
# scripts/security/binaries-fetch.sh - downloads a release's built binaries for
# the binaries job of check-security.yml. Covers every way out of it: binaries
# downloaded and their directory published, a release with no binaries (gh's
# two "no assets" wordings, and a download that succeeds with nothing in it),
# and each failure - no gh, no directory given, no tag, a release that does not
# exist (named with its repository), and a download that breaks.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# binaries-fetch.sh is the one security bridge that talks to GitHub rather than
# to the consumer. A fake gh stands in: `release view` succeeds for any tag but
# v-missing; `release download` writes whatever $FAKE_ASSETS names into --dir,
# or fails the way the real gh does for no match ($FAKE_NO_ASSETS) or for a
# broken download ($FAKE_BROKEN). Every call is recorded.
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

@test "binaries-fetch.sh fails when gh is not on the PATH" {
  local bin="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bin"
  ln -sf "$(command -v dirname)" "$bin/dirname"
  run env PATH="$bin" "$BASH" "$REPO_ROOT/scripts/security/binaries-fetch.sh" v1.2.3 "$BATS_TEST_TMPDIR/bin-out"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: gh' || fail "the error does not name gh: $output"
  [ ! -e "$BATS_TEST_TMPDIR/bin-out" ] || fail "the directory was created before the check for gh"
}

@test "binaries-fetch.sh without a directory fails with its usage, before calling gh" {
  fake_gh
  run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" v1.2.3
  [ "$status" -ne 0 ] || fail "a call naming no directory passed: $output"
  contains "$output" 'usage: binaries-fetch.sh TAG DIR' || fail "the error does not show the usage: $output"
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ] || fail "gh was called with no directory: $(cat "$BATS_TEST_TMPDIR/gh-calls")"
}

@test "binaries-fetch.sh names the repository from GH_REPO when the release does not exist" {
  fake_gh
  export GH_REPO="blinkbitcoin/example-app"
  run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" v-missing "$BATS_TEST_TMPDIR/bin-out"
  [ "$status" -eq 1 ] || fail "a missing release did not fail: $output"
  contains "$output" "::error::release v-missing was not found in blinkbitcoin/example-app" \
    || fail "the error does not name the repository: $output"
  [ ! -e "$BATS_TEST_TMPDIR/bin-out" ] || fail "the directory was created for a release that does not exist"
}

@test "binaries-fetch.sh reports a download that succeeds with no binaries as a notice, not a count" {
  fake_gh
  export FAKE_ASSETS=""
  run bash "$REPO_ROOT/scripts/security/binaries-fetch.sh" v1.2.3 "$BATS_TEST_TMPDIR/bin-out"
  [ "$status" -eq 0 ] || fail "an empty download failed the step: $output"
  contains "$output" "::notice::release v1.2.3 carries no .apk, .aab or .ipa" \
    || fail "an empty download was not reported as a notice: $output"
  not_contains "$output" "file(s) from" || fail "an empty download was logged as a count: $output"
  grep -qxF "SECURITY_BINARIES_DIR=$(cd "$BATS_TEST_TMPDIR/bin-out" && pwd -P)" "$GITHUB_ENV" \
    || fail "SECURITY_BINARIES_DIR was not published: $(cat "$GITHUB_ENV")"
}
