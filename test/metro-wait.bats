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
