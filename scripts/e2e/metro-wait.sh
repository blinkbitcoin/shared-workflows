#!/usr/bin/env bash
# Wait for Metro (metro-start.sh) and prewarm the bundle for the given platform
# so the first app launch does not race a cold transform of the whole graph.
# The URL comes from the dev server's own manifest rather than being built here
# (see the prewarm block below); the fallback is Expo's virtual entry, not
# index.bundle, because expo-router apps have no physical entry file. A bare
# app's Metro (`react-native start`) serves no manifest, and its app asks for
# index.bundle, so that is what is warmed for the bare native stack.
# Usage: metro-wait.sh <ios|android>
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

platform="$(workflows_platform "${1:-}")"
require_cmd curl
base="http://localhost:$WORKFLOWS_METRO_PORT"

tail_metro_log() {
  log "--- tail of $WORKFLOWS_OUT/metro.log ---"
  tail -50 "$WORKFLOWS_OUT/metro.log" >&2 || true
}

ready=false
for i in $(seq 1 90); do
  if curl -s --max-time 5 "$base/status" | grep -q packager-status:running; then
    log "Metro is ready (after $((i * 2))s)"
    ready=true
    break
  fi
  # Metro that died on a port clash or a config error is never coming back;
  # waiting out the full 180s only hides the reason in a timeout message.
  if [ -f "$WORKFLOWS_OUT/metro.pid" ] && ! kill -0 "$(cat "$WORKFLOWS_OUT/metro.pid")" 2>/dev/null; then
    tail_metro_log
    die "Metro (pid $(cat "$WORKFLOWS_OUT/metro.pid")) exited before becoming ready"
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  tail_metro_log
  die "Metro did not report packager-status:running within 180s"
fi

# Prewarming only pays off if it warms *the* graph the app then asks for. Metro
# keys its transform cache on the full option set carried in the bundle URL
# (metro/src/lib/getGraphId.js), and the URL the dev client actually requests is
# `launchAsset.url` from the manifest - which, for a Hermes app, additionally
# carries `transform.bytecode=1`, `transform.routerRoot=<dir>` and
# `unstable_transformProfile=hermes-stable` (@expo/cli's ManifestMiddleware
# `_getBundleUrl` → metroOptions `createBundleUrlPath`). A hand-built URL that
# differs in any one of them warms a second graph and the first real launch
# still pays for a cold transform. So ask the server, and only guess when it
# cannot answer.
#
# The manifest is served from `/` when the request carries `expo-platform`;
# `accept: application/json` picks the plain JSON body over the multipart form
# an expo-updates client would get.
manifest_bundle_path() {
  local manifest url rest
  command -v jq > /dev/null 2>&1 || return 1
  manifest="$(curl -sf --max-time 30 \
    -H "expo-platform: $platform" -H 'accept: application/json' "$base/")" || return 1
  url="$(printf '%s' "$manifest" | jq -r '.launchAsset.url // empty' 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  # Re-anchor on our own base: the manifest's host is whatever `host:` header
  # the server saw, which is not necessarily reachable from this process.
  rest="${url#*://}"
  case "$rest" in
    */*) printf '/%s\n' "${rest#*/}" ;;
    *) return 1 ;;
  esac
}

group "prewarming the $platform bundle"
stack="$(bash "$WORKFLOWS_LIB_DIR/native-stack.sh")" || die "could not resolve the native stack"
# The URL Expo built before the manifest existed. Kept as the fallback so a
# non-dev-client app, a jq-less machine or an unexpected manifest shape still
# gets a warm graph - just not necessarily the app's own.
fallback="/.expo/.virtual-metro-entry.bundle?platform=$platform&dev=true&hot=false&lazy=true&transform.engine=hermes"
if [ "$stack" = bare ]; then
  # What a bare React Native app's AppDelegate / MainApplication requests in
  # Debug: the physical index.js entry, with the CLI's default transform options.
  path="/index.bundle?platform=$platform&dev=true&lazy=true&minify=false&inlineSourceMap=false&modulesOnly=false&runModule=true"
  log "prewarming the bare app's entry: $path"
elif path="$(manifest_bundle_path)"; then
  log "prewarming the manifest's launchAsset: $path"
else
  printf '::warning::could not read launchAsset.url from the %s manifest; prewarming the hand-built bundle URL, which may warm a different graph than the app requests\n' "$platform"
  path="$fallback"
fi
# The first bundle build of a cold app is minutes on a runner; do it here so a
# launch timeout later means a real launch problem.
curl -sf --max-time 300 "$base$path" -o /dev/null || die "bundle prewarm failed for $platform"
endgroup
log "Bundle prewarmed ($platform)"
