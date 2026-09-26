#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ota/smoke.sh: fetching the published manifest for a channel the way a
# client would, and failing when the update server does not serve it. Covers the
# request headers (runtime version and platform, set and unset), the skip when
# no manifest URL is configured, and every way it fails: a missing channel, no
# curl, a failed request, a non-200 answer and an empty one - with the fetched
# body cleaned up on both outcomes.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/cmd.log"
  : > "$WORKFLOWS_TEST_LOG"
  export PATH="$STUB:$PATH"
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_OTA_DIR="$BATS_TEST_TMPDIR/ota" WORKFLOWS_ASSETS_DIR="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_ENV OTA_MANIFEST_URL OTA_RUNTIME_VERSION OTA_SMOKE_PLATFORM
}

stub_curl() {
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
prev=""; out=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '%s' "${WORKFLOWS_TEST_MANIFEST-manifest bytes}" > "$out"
[ "${WORKFLOWS_TEST_CURL_FAIL:-}" = "true" ] && exit 7
printf '%s' "${WORKFLOWS_TEST_CODE:-200}"
exit 0
SH
  chmod +x "$STUB/curl"
}

smoke() { run bash "$REPO_ROOT/scripts/ota/smoke.sh" "$@"; }

@test "smoke fetches the manifest with the headers a client sends" {
  stub_curl
  OTA_MANIFEST_URL=https://u.example.test/manifest OTA_RUNTIME_VERSION=1.0.0 smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(grep '^curl ' "$WORKFLOWS_TEST_LOG")"
  contains "$argv" "expo-channel-name: beta" || fail "no channel header: $argv"
  contains "$argv" "expo-platform: ios" || fail "no platform header: $argv"
  contains "$argv" "expo-runtime-version: 1.0.0" || fail "no runtime header: $argv"
  contains "$argv" "https://u.example.test/manifest" || fail "wrong url: $argv"
}

@test "an unset runtime version contributes no header at all" {
  stub_curl
  OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$(grep '^curl ' "$WORKFLOWS_TEST_LOG")" "expo-runtime-version" \
    || fail "an empty runtime version became a header"
}

@test "an empty manifest url skips the check instead of failing" {
  stub_curl
  smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "called curl anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

# A publish that "succeeded" but serves nothing looks exactly like a working one
# until a user opens the app.
@test "a non-200 manifest is fatal" {
  stub_curl
  WORKFLOWS_TEST_CODE=404 OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "accepted HTTP 404: $output"
  contains "$output" "returned HTTP 404" || fail "unexpected message: $output"
}

@test "an empty 200 manifest is fatal" {
  stub_curl
  WORKFLOWS_TEST_MANIFEST='' OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "accepted an empty manifest: $output"
  contains "$output" "came back empty" || fail "unexpected message: $output"
}

@test "a failed request is fatal" {
  stub_curl
  WORKFLOWS_TEST_CURL_FAIL=true OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "a failed request was ignored: $output"
  contains "$output" "failed" || fail "unexpected message: $output"
}

@test "the smoke body does not survive the run" {
  stub_curl
  OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -f "$RUNNER_TEMP/workflows-ota-manifest" ] || fail "left the manifest body behind"
}

@test "a served manifest is reported as served" {
  stub_curl
  OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "HTTP 200, 14 bytes" || fail "the response was not summarised: $output"
  contains "$output" "manifest for beta is being served" || fail "unexpected message: $output"
}

@test "OTA_SMOKE_PLATFORM chooses the platform the manifest is fetched for" {
  stub_curl
  OTA_SMOKE_PLATFORM=android OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(grep '^curl ' "$WORKFLOWS_TEST_LOG")"
  contains "$argv" "expo-platform: android" || fail "the platform was not passed on: $argv"
  not_contains "$argv" "expo-platform: ios" || fail "the default platform was sent as well: $argv"
}

@test "the smoke body does not survive a failed check either" {
  stub_curl
  WORKFLOWS_TEST_CODE=500 OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "accepted HTTP 500: $output"
  [ ! -f "$RUNNER_TEMP/workflows-ota-manifest" ] || fail "left the manifest body behind after a failure"
}

@test "a missing channel is fatal, with the usage" {
  stub_curl
  OTA_MANIFEST_URL=https://u.example.test/manifest smoke
  [ "$status" -ne 0 ] || fail "ran without a channel: $output"
  contains "$output" "usage: smoke.sh CHANNEL" || fail "unexpected message: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "called curl anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "without curl on PATH a configured smoke is fatal, and names the command" {
  # A PATH of symlinks to exactly what the script runs before its curl check:
  # macOS and the runner images both ship a curl in /usr/bin.
  nocurl="$BATS_TEST_TMPDIR/nocurl"
  mkdir -p "$nocurl"
  for c in bash dirname mkdir; do
    p="$(command -v "$c")" && ln -sf "$p" "$nocurl/$c"
  done
  PATH="$nocurl" OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "ran without curl: $output"
  contains "$output" "missing command: curl" || fail "unexpected message: $output"
}
