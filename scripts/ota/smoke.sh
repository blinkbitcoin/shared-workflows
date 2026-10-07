#!/usr/bin/env bash
# Fetch the published manifest for a channel and assert the update server
# actually serves it.
#
# A publish that "succeeded" but serves nothing is indistinguishable from a
# working one until a user opens the app, so this fetches the manifest the
# client would fetch, with the same expo-* headers, and fails when it does not
# come back.
#
# With no OTA_RUNTIME_VERSION, the runtime version is the platform's fingerprint
# in OTA_BASELINE_BUILD_INFO, the channel's baseline: the fingerprint gate only
# lets an update through when this commit fingerprints the same, and that
# fingerprint is the runtime version the update is served under.
#
# Usage: smoke.sh CHANNEL
# Env: OTA_MANIFEST_URL (empty skips the smoke), OTA_RUNTIME_VERSION,
#      OTA_BASELINE_BUILD_INFO, OTA_SMOKE_PLATFORM (default ios).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"

channel="${1:?usage: smoke.sh CHANNEL}"
url="${OTA_MANIFEST_URL:-}"
if [ -z "$url" ]; then
  log "OTA_MANIFEST_URL is empty - skipping the manifest smoke check"
  exit 0
fi
require_cmd curl

platform="${OTA_SMOKE_PLATFORM:-ios}"
body="${RUNNER_TEMP:-/tmp}/workflows-ota-manifest"
trap 'rm -f "$body"' EXIT

runtime="${OTA_RUNTIME_VERSION:-}"
baseline="${OTA_BASELINE_BUILD_INFO:-}"
if [ -z "$runtime" ] && [ -n "$baseline" ] && [ -f "$baseline" ]; then
  require_cmd yq
  runtime="$(yq -r ".fingerprint.$platform // \"\"" "$baseline")" || die "could not read fingerprint.$platform from $baseline"
  [ "$runtime" != "null" ] || runtime=""
  [ -z "$runtime" ] || log "runtime version: the baseline's $platform fingerprint, $runtime"
fi

# Built as an array so an unset runtime version contributes no argument at all
# (an unquoted ${VAR:+-H "..."} would word-split the header on its space).
runtime_args=()
[ -z "$runtime" ] || runtime_args=(-H "expo-runtime-version: $runtime")

# One request for the manifest, setting `code`. It fails only for what asking
# again can fix: no answer at all, or a 5xx from a server that is restarting or
# overloaded. Any other status is the server's answer, judged below. Its
# failures are explicit returns, because retry_command runs it where `set -e`
# does not apply.
fetch_manifest() {
  code="$(curl -sS -o "$body" -w '%{http_code}' \
    -H "expo-channel-name: $channel" \
    -H "expo-platform: $platform" \
    -H "expo-protocol-version: 1" \
    -H "expo-api-version: 1" \
    "${runtime_args[@]+"${runtime_args[@]}"}" \
    -H 'accept: multipart/mixed' \
    "$url")" || { code=""; log "manifest request to $url failed"; return 1; }
  log "HTTP $code, $(wc -c < "$body" | tr -d ' ') bytes"
  case "$code" in 5??) return 1 ;; esac
}

# Three attempts, 5 seconds apart: enough to ride out a dropped connection or a
# server restart, short enough that a manifest that is really missing fails
# fast. A GET of the manifest changes nothing on the server, so repeating it is
# safe.
group "ota manifest smoke ($channel)"
code=""
if ! retry_command 3 5 -- fetch_manifest; then
  [ -n "$code" ] || die "manifest request to $url failed"
fi
endgroup

[ "$code" = "200" ] || die "manifest for $channel returned HTTP $code (expected 200)"
[ -s "$body" ] || die "manifest for $channel came back empty"
log "manifest for $channel is being served"
