#!/usr/bin/env bats
load test_helper

setup() {
  EXPO_CONFIG_JSON="$FIXTURES/expo-config.json"
  export EXPO_CONFIG_JSON
}

@test "extracts name" {
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -eq 0 ]
  [ "$output" = "RN Mobile Template (dev)" ]
}

@test "extracts slug" {
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" slug
  [ "$status" -eq 0 ]
  [ "$output" = "react-native-mobile-template" ]
}

@test "extracts scheme" {
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" scheme
  [ "$status" -eq 0 ]
  [ "$output" = "rnmt" ]
}

@test "extracts ios.bundleIdentifier" {
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" ios.bundleIdentifier
  [ "$status" -eq 0 ]
  [ "$output" = "com.example.rnmt.dev" ]
}

@test "extracts android.package" {
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" android.package
  [ "$status" -eq 0 ]
  [ "$output" = "com.example.rnmt.dev" ]
}

@test "derives ios.scheme-name by stripping non-alphanumerics from name" {
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" ios.scheme-name
  [ "$status" -eq 0 ]
  [ "$output" = "RNMobileTemplatedev" ]
}

@test "unknown key exits 1 with an ::error annotation" {
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" nonexistent.key
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]] || fail "assertion failed; output: $output"
}

# --- the cache must never hold the output of a failed run --------------------
#
# A plain `expo config ... > "$json_file"` creates the file before expo runs, so
# a failure left a zero-byte file behind - which the `[ ! -f ]` fast path then
# accepted as a warm cache. Every later call in the job read an empty config and
# reported "key not found" instead of the failure that actually happened.
#
# These tests run the uncached path, so EXPO_CONFIG_JSON must be out of the way
# and `pnpm` must be a stub: the real one would go and build a config.

cache_setup() {
  unset EXPO_CONFIG_JSON
  RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  export RUNNER_TEMP
  ROOT="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$ROOT"
  export GITHUB_SHA=cafebabe
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  PATH="$STUB:$PATH"
  export PATH
}

# Writes a `pnpm` stub whose `exec expo config` behaves as asked.
stub_pnpm() {
  case "$1" in
    ok) printf '#!/usr/bin/env bash\nprintf %%s "{\\"name\\":\\"Stubbed\\",\\"slug\\":\\"s\\"}"\n' > "$STUB/pnpm" ;;
    fail) printf '#!/usr/bin/env bash\necho "expo blew up" >&2\nexit 3\n' > "$STUB/pnpm" ;;
    empty) printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/pnpm" ;;
  esac
  chmod +x "$STUB/pnpm"
}

cached_file() { find "$RUNNER_TEMP" -name 'workflows-expo-config-*.json' 2>/dev/null; }

@test "a failed expo config leaves no cache file behind" {
  cache_setup
  stub_pnpm fail
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -ne 0 ] || fail "a failed expo config succeeded: $output"
  contains "$output" "expo config failed" || fail "the error does not name the failure: $output"
  [ -z "$(cached_file)" ] || fail "a cache file survived a failed run: $(cached_file) ($(wc -c < "$(cached_file)") bytes)"
}

@test "a failed run does not poison the next one" {
  # The actual damage: with an empty file cached, the *next* call took the fast
  # path and reported a missing key rather than re-running expo.
  cache_setup
  stub_pnpm fail
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -ne 0 ] || fail "the first call should have failed: $output"
  stub_pnpm ok
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -eq 0 ] || fail "the second call inherited the first failure: $output"
  [ "$output" = "Stubbed" ] || fail "unexpected value: $output"
}

@test "expo config succeeding with no output is refused, not cached" {
  cache_setup
  stub_pnpm empty
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -ne 0 ] || fail "an empty config was accepted: $output"
  contains "$output" "no output" || fail "unexpected message: $output"
  [ -z "$(cached_file)" ] || fail "an empty cache file was written: $(cached_file)"
}

@test "a successful run is cached, and expo is not spawned again" {
  cache_setup
  stub_pnpm ok
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -n "$(cached_file)" ] || fail "nothing was cached"
  # Remove the stub entirely: a second call that still answers proves it read
  # the cache rather than re-running expo.
  rm -f "$STUB/pnpm"
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" slug
  [ "$status" -eq 0 ] || fail "the cache was not used: $output"
  [ "$output" = "s" ] || fail "unexpected value: $output"
}

@test "the cache key includes the commit, so a new checkout is not served a stale config" {
  # app.config.ts reads git state and the environment, so the same directory at
  # two commits is two different configs - and in CI the directory keeps its
  # name across a re-checkout.
  cache_setup
  stub_pnpm ok
  run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  first="$(cached_file)"
  GITHUB_SHA=d00dfeed run bash "$REPO_ROOT/scripts/lib/expo-config.sh" name
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cached_file | wc -l)" -eq 2 ] || fail "the second commit reused the first commit's cache file: $first"
}
