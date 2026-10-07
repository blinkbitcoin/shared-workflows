#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ota/smoke.sh: fetching the published manifest for a channel the way a
# client would, and failing when the update server does not serve it. Covers the
# request headers (runtime version and platform, set and unset), the skip when
# no manifest URL is configured, and every way it fails: a missing channel, no
# curl, a failed request, a non-200 answer and an empty one - with the fetched
# body cleaned up on both outcomes - and the retries: a dropped connection or a
# 5xx is asked again, three times in all, while any other answer is final.
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
  # The retries run without their 5-second wait.
  export WORKFLOWS_RETRY_DELAY_SECONDS=0
  unset GITHUB_ENV OTA_MANIFEST_URL OTA_RUNTIME_VERSION OTA_SMOKE_PLATFORM OTA_BASELINE_BUILD_INFO
}

stub_curl() {
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
calls="$(grep -c '^curl ' "$WORKFLOWS_TEST_LOG")"
prev=""; out=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '%s' "${WORKFLOWS_TEST_MANIFEST-manifest bytes}" > "$out"
[ "${WORKFLOWS_TEST_CURL_FAIL:-}" = "true" ] && exit 7
# The first WORKFLOWS_TEST_FAIL_FIRST calls fail: no answer (exit 7), or the
# status in WORKFLOWS_TEST_FAIL_CODE when it is set.
if [ "$calls" -le "${WORKFLOWS_TEST_FAIL_FIRST:-0}" ]; then
  [ -n "${WORKFLOWS_TEST_FAIL_CODE:-}" ] || exit 7
  printf '%s' "$WORKFLOWS_TEST_FAIL_CODE"
  exit 0
fi
printf '%s' "${WORKFLOWS_TEST_CODE:-200}"
exit 0
SH
  as_fakes "$STUB/curl"
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
@test "a non-200 manifest is fatal, and a 4xx is not asked again" {
  stub_curl
  WORKFLOWS_TEST_CODE=404 OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "accepted HTTP 404: $output"
  contains "$output" "returned HTTP 404" || fail "unexpected message: $output"
  [ "$(grep -c '^curl ' "$WORKFLOWS_TEST_LOG")" -eq 1 ] || fail "a 404 was retried: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a dropped connection is asked again, and the second answer counts" {
  stub_curl
  WORKFLOWS_TEST_FAIL_FIRST=1 OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "one dropped connection failed the smoke: $output"
  [ "$(grep -c '^curl ' "$WORKFLOWS_TEST_LOG")" -eq 2 ] || fail "expected two requests: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "attempt 1 of 3 failed with exit status 1: fetch_manifest - retrying in 0s" || fail "the retry was not logged: $output"
  contains "$output" "manifest for beta is being served" || fail "unexpected message: $output"
}

@test "a 5xx is asked again, and the second answer counts" {
  stub_curl
  WORKFLOWS_TEST_FAIL_FIRST=1 WORKFLOWS_TEST_FAIL_CODE=503 OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "one 503 failed the smoke: $output"
  [ "$(grep -c '^curl ' "$WORKFLOWS_TEST_LOG")" -eq 2 ] || fail "expected two requests: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "HTTP 503" || fail "the 503 was not logged: $output"
}

@test "a 5xx on every attempt is fatal after three requests, naming the status" {
  stub_curl
  WORKFLOWS_TEST_FAIL_FIRST=99 WORKFLOWS_TEST_FAIL_CODE=502 OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "accepted HTTP 502: $output"
  [ "$(grep -c '^curl ' "$WORKFLOWS_TEST_LOG")" -eq 3 ] || fail "expected three requests: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "attempt 3 of 3 failed with exit status 1: fetch_manifest - giving up" || fail "the last attempt was not logged: $output"
  contains "$output" "returned HTTP 502" || fail "unexpected message: $output"
}

@test "an empty 200 manifest is fatal" {
  stub_curl
  WORKFLOWS_TEST_MANIFEST='' OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "accepted an empty manifest: $output"
  contains "$output" "came back empty" || fail "unexpected message: $output"
}

@test "a request that fails on every attempt is fatal after three requests" {
  stub_curl
  WORKFLOWS_TEST_CURL_FAIL=true OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "a failed request was ignored: $output"
  [ "$(grep -c '^curl ' "$WORKFLOWS_TEST_LOG")" -eq 3 ] || fail "expected three requests: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "::error::manifest request to https://u.example.test/manifest failed" || fail "unexpected message: $output"
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

# The channel's baseline, as baseline.sh leaves it for the smoke step.
baseline_file() {
  export OTA_BASELINE_BUILD_INFO="$BATS_TEST_TMPDIR/build-info.json"
  printf '%s' "$1" > "$OTA_BASELINE_BUILD_INFO"
}

@test "with no runtime version, the baseline's iOS fingerprint is sent" {
  stub_curl
  baseline_file '{"fingerprint":{"ios":"fingerprint-ios","android":"fingerprint-android"}}'
  OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(grep '^curl ' "$WORKFLOWS_TEST_LOG")" "expo-runtime-version: fingerprint-ios" || fail "the baseline fingerprint was not sent"
  contains "$output" "runtime version: the baseline's ios fingerprint, fingerprint-ios" || fail "the source was not logged: $output"
}

@test "the baseline fingerprint follows OTA_SMOKE_PLATFORM" {
  stub_curl
  baseline_file '{"fingerprint":{"ios":"fingerprint-ios","android":"fingerprint-android"}}'
  OTA_SMOKE_PLATFORM=android OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(grep '^curl ' "$WORKFLOWS_TEST_LOG")"
  contains "$argv" "expo-runtime-version: fingerprint-android" || fail "the android fingerprint was not sent: $argv"
  not_contains "$argv" "fingerprint-ios" || fail "the iOS fingerprint was sent for android: $argv"
}

@test "an explicit runtime version wins over the baseline" {
  stub_curl
  baseline_file '{"fingerprint":{"ios":"fingerprint-ios"}}'
  OTA_RUNTIME_VERSION=1.0.0 OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(grep '^curl ' "$WORKFLOWS_TEST_LOG")"
  contains "$argv" "expo-runtime-version: 1.0.0" || fail "the explicit version was not sent: $argv"
  not_contains "$argv" "fingerprint-ios" || fail "the baseline overrode the explicit version: $argv"
}

@test "a baseline with no fingerprint for the platform, or no baseline file, sends no runtime header" {
  stub_curl
  baseline_file '{"fingerprint":{"android":"fingerprint-android"}}'
  OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$(grep '^curl ' "$WORKFLOWS_TEST_LOG")" "expo-runtime-version" || fail "sent a header from a missing fingerprint"
  : > "$WORKFLOWS_TEST_LOG"
  OTA_BASELINE_BUILD_INFO="$BATS_TEST_TMPDIR/absent.json" OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -eq 0 ] || fail "exited $status with no baseline file: $output"
  not_contains "$(grep '^curl ' "$WORKFLOWS_TEST_LOG")" "expo-runtime-version" || fail "sent a header with no baseline file"
}

@test "a baseline that is not JSON is fatal" {
  stub_curl
  baseline_file '{not json'
  OTA_MANIFEST_URL=https://u.example.test/manifest smoke beta
  [ "$status" -ne 0 ] || fail "accepted an unreadable baseline: $output"
  contains "$output" "could not read fingerprint.ios from $OTA_BASELINE_BUILD_INFO" || fail "unexpected message: $output"
}
