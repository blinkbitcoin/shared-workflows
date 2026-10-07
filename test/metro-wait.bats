#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# `curl` is stubbed: what is under test is *which URL* gets prewarmed, not
# Metro. The point of the suite is the graph-id contract - Metro keys its
# transform cache on the full option set in the bundle URL, so a prewarm that
# guesses the options warms a graph the app never asks for and the first launch
# still builds from cold.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/curl.log"
  : > "$WORKFLOWS_TEST_LOG"
  export WORKFLOWS_TEST_MANIFEST="$FIXTURES/expo-manifest.json"
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */status)
    [ "${WORKFLOWS_TEST_METRO_DOWN:-}" = true ] && exit 7
    # Not running yet for the first READY_AFTER-1 polls.
    if [ -n "${WORKFLOWS_TEST_METRO_READY_AFTER:-}" ]; then
      polls="$(grep -c '/status' "$WORKFLOWS_TEST_LOG")"
      [ "$polls" -ge "$WORKFLOWS_TEST_METRO_READY_AFTER" ] || { printf 'packager-status:starting'; exit 0; }
    fi
    printf 'packager-status:running'
    exit 0
    ;;
  */)
    [ "${WORKFLOWS_TEST_MANIFEST_FAIL:-}" = true ] && exit 22
    cat "$WORKFLOWS_TEST_MANIFEST"
    exit 0
    ;;
  *)
    exit "${WORKFLOWS_TEST_BUNDLE_STATUS:-0}"
    ;;
esac
SH
  chmod +x "$STUB/curl"
  # Run the stub once before the script does: macOS scans a new executable on
  # its first run, for seconds, and the cases below time Metro's first poll.
  "$STUB/curl" http://localhost/warm-up > /dev/null
  : > "$WORKFLOWS_TEST_LOG"
  export PATH="$STUB:$PATH"
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$WORKFLOWS_OUT"
  unset GITHUB_ENV
  # The Expo stack unless a case says otherwise: the manifest is Expo's.
  export WORKFLOWS_NATIVE_STACK_INPUT=expo
}

wait_for_metro() { run bash "$REPO_ROOT/scripts/e2e/metro-wait.sh" "$@"; }

# The prewarmed URL is the last one the stub saw.
prewarmed() { grep '^curl ' "$WORKFLOWS_TEST_LOG" | tail -1; }

@test "prewarms the manifest's launchAsset URL, rebased on the local base" {
  wait_for_metro ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  # The three options a hand-built URL misses; each one alone is a different
  # graph id, so each one alone means a wasted prewarm.
  for opt in "transform.bytecode=1" "transform.routerRoot=app" "unstable_transformProfile=hermes-stable"; do
    contains "$(prewarmed)" "$opt" || fail "$opt missing from the prewarm: $(prewarmed)"
  done
  # Rebased: the fixture's manifest advertises 192.168.1.42, which is not
  # necessarily reachable from the runner.
  contains "$(prewarmed)" "http://localhost:8081/.expo/" || fail "not rebased on the local base: $(prewarmed)"
  not_contains "$(prewarmed)" "192.168.1.42" || fail "used the manifest's host: $(prewarmed)"
  not_contains "$output" "::warning::" || fail "warned on the happy path: $output"
}

@test "asks for the manifest with the expo-platform and JSON accept headers" {
  wait_for_metro android
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  manifest_call="$(grep -- '-H expo-platform' "$WORKFLOWS_TEST_LOG" || true)"
  [ -n "$manifest_call" ] || fail "no manifest request was made: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$manifest_call" "expo-platform: android" || fail "wrong platform header: $manifest_call"
  # Without this the dev server answers an expo-updates client with a
  # multipart/mixed body that jq cannot read.
  contains "$manifest_call" "accept: application/json" || fail "no JSON accept header: $manifest_call"
}

@test "falls back to the hand-built URL, loudly, when the manifest request fails" {
  WORKFLOWS_TEST_MANIFEST_FAIL=true wait_for_metro ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning::" || fail "the fallback was silent: $output"
  contains "$(prewarmed)" ".expo/.virtual-metro-entry.bundle?platform=ios" \
    || fail "unexpected fallback URL: $(prewarmed)"
}

@test "falls back when the manifest carries no launchAsset url" {
  printf '%s\n' '{"id":"x","launchAsset":{}}' > "$BATS_TEST_TMPDIR/empty.json"
  WORKFLOWS_TEST_MANIFEST="$BATS_TEST_TMPDIR/empty.json" wait_for_metro ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning::" || fail "the fallback was silent: $output"
  contains "$(prewarmed)" ".virtual-metro-entry.bundle" || fail "unexpected fallback URL: $(prewarmed)"
}

@test "a failed prewarm is fatal" {
  WORKFLOWS_TEST_BUNDLE_STATUS=1 wait_for_metro ios
  [ "$status" -ne 0 ] || fail "a failed prewarm was ignored: $output"
  contains "$output" "bundle prewarm failed for ios" || fail "unexpected message: $output"
}

# Metro that died on a port clash is never coming back; waiting out the full
# 180s only hides the reason in a timeout message.
@test "a Metro that exited before becoming ready is fatal immediately" {
  printf '999999\n' > "$WORKFLOWS_OUT/metro.pid"
  : > "$WORKFLOWS_OUT/metro.log"
  WORKFLOWS_TEST_METRO_DOWN=true wait_for_metro ios
  [ "$status" -ne 0 ] || fail "waited on a dead Metro: $output"
  contains "$output" "exited before becoming ready" || fail "unexpected message: $output"
  [ -z "$(prewarmed | grep bundle || true)" ] || fail "prewarmed anyway: $(prewarmed)"
}

status_polls() { grep -c '/status' "$WORKFLOWS_TEST_LOG" || true; }
elapsed_in() { sed -n 's/.*Metro is ready (after \([0-9][0-9]*\)s).*/\1/p' <<<"$1"; }

# The bound is real time, not a count of tries: a loop of 90 tries of a 5s curl
# plus a 2s sleep said 180s and could wait 630s.
@test "a Metro that is alive but never ready times out at the stated bound, naming it" {
  # A pid that is alive for as long as the test runs: the test's own shell.
  printf '%s\n' "$$" > "$WORKFLOWS_OUT/metro.pid"
  printf 'still starting\n' > "$WORKFLOWS_OUT/metro.log"
  WORKFLOWS_TEST_METRO_DOWN=true WORKFLOWS_METRO_WAIT_SECONDS=1 wait_for_metro ios
  [ "$status" -ne 0 ] || fail "a Metro that never became ready passed: $output"
  contains "$output" "did not report packager-status:running within 1s (gave up after " \
    || fail "the message does not name the real bound: $output"
  contains "$output" "still starting" || fail "no tail of metro.log: $output"
  not_contains "$output" "exited before becoming ready" || fail "a live Metro was reported dead: $output"
  gave_up="$(sed -n 's/.*(gave up after \([0-9][0-9]*\)s).*/\1/p' <<<"$output")"
  [ -n "$gave_up" ] && [ "$gave_up" -ge 1 ] || fail "gave up before the deadline: $output"
  [ -z "$(prewarmed | grep bundle || true)" ] || fail "prewarmed anyway: $(prewarmed)"
}

@test "a Metro ready on the first poll reports the real elapsed time, not a loop count" {
  wait_for_metro ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  elapsed="$(elapsed_in "$output")"
  # The loop-count message said 2s for the first poll; no time has passed.
  [ -n "$elapsed" ] && [ "$elapsed" -le 1 ] || fail "expected about 0s: $output"
  [ "$(status_polls)" -eq 1 ] || fail "polled more than once: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a Metro ready after a few polls reports the seconds really waited" {
  WORKFLOWS_TEST_METRO_READY_AFTER=2 wait_for_metro ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(status_polls)" -eq 2 ] || fail "expected two polls: $(cat "$WORKFLOWS_TEST_LOG")"
  elapsed="$(elapsed_in "$output")"
  # One 2s interval between the polls; a busy machine may add to it, never take away.
  [ -n "$elapsed" ] && [ "$elapsed" -ge 2 ] || fail "expected at least 2s: $output"
}

@test "a wait that is not a whole number of seconds is fatal" {
  WORKFLOWS_METRO_WAIT_SECONDS=soon wait_for_metro ios
  [ "$status" -ne 0 ] || fail "accepted a non-number: $output"
  contains "$output" "WORKFLOWS_METRO_WAIT_SECONDS must be a whole number of seconds, got 'soon'" || fail "output: $output"
}

@test "a missing or bogus platform is fatal" {
  wait_for_metro
  [ "$status" -ne 0 ] || fail "accepted an empty platform: $output"
  contains "$output" "platform must be ios or android" || fail "unexpected message: $output"
}

# A bare app's Metro serves no Expo manifest and its app asks for index.bundle,
# so that is what is warmed - never the manifest, never Expo's virtual entry.
@test "the bare stack prewarms index.bundle, without asking for a manifest" {
  GITHUB_WORKSPACE="$FIXTURES" WORKING_DIRECTORY=consumer-bare WORKFLOWS_NATIVE_STACK_INPUT='' wait_for_metro android
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "native stack: bare" || fail "the stack was not detected: $output"
  contains "$(prewarmed)" "http://localhost:8081/index.bundle?platform=android&dev=true&lazy=true&minify=false" || fail "prewarmed: $(prewarmed)"
  not_contains "$(cat "$WORKFLOWS_TEST_LOG")" "expo-platform" || fail "asked for an Expo manifest: $(cat "$WORKFLOWS_TEST_LOG")"
  not_contains "$output" "::warning::" || fail "warned about a manifest a bare Metro never serves: $output"
}

@test "an invalid native-stack input fails before the prewarm" {
  WORKFLOWS_NATIVE_STACK_INPUT=web wait_for_metro ios
  [ "$status" -ne 0 ] || fail "accepted web: $output"
  contains "$output" "could not resolve the native stack" || fail "output: $output"
}
