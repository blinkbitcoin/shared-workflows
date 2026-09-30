#!/usr/bin/env bash
# Extract a value out of `expo config --json --type public`, caching the JSON
# per consumer so repeated calls in one CI job don't re-spawn Metro/expo-cli.
# EXPO_CONFIG_JSON overrides the source entirely (used by unit tests to feed
# a fixture without running expo).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

refresh=false
key=""
for arg in "$@"; do
  case "$arg" in
    --refresh) refresh=true ;;
    *) key="$arg" ;;
  esac
done
[ -n "$key" ] || die "usage: expo-config.sh [--refresh] KEY"

if [ -n "${EXPO_CONFIG_JSON:-}" ]; then
  json_file="$EXPO_CONFIG_JSON"
  [ -f "$json_file" ] || die "EXPO_CONFIG_JSON not found: $json_file"
else
  require_cmd pnpm yq shasum
  root="$(consumer_root)"
  # The commit is part of the key, not just the path. app.config.ts reads the
  # git state and the environment, so the same directory at two different
  # commits is two different configs - and in CI that directory keeps its name
  # across a re-checkout, so a path-only key served the previous commit's answer.
  cache_key=$(printf '%s\n%s' "$root" "${GITHUB_SHA:-nosha}" | shasum -a 256 | cut -c1-16)
  json_file="${RUNNER_TEMP:-/tmp}/workflows-expo-config-$cache_key.json"
  if [ "$refresh" = true ] || [ ! -f "$json_file" ]; then
    # Written to a temp file and moved into place only on success. A plain
    # redirect creates $json_file *before* expo runs, so a failed run left a
    # zero-byte file behind - which the `[ ! -f ]` test above then accepted as a
    # warm cache, and every later call in the job read an empty config and
    # reported a missing key instead of the real failure.
    tmp_file="$json_file.$$.tmp"
    if (cd "$root" && pnpm exec expo config --json --type public) > "$tmp_file"; then
      # Exit 0 with no output is the same trap one step further on: it would be
      # cached and read as a config with no keys in it.
      if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        die "expo config produced no output in $root; no cache was written"
      fi
      mv "$tmp_file" "$json_file"
    else
      status=$?
      rm -f "$tmp_file"
      die "expo config failed in $root (exit $status); no cache was written"
    fi
  fi
fi

case "$key" in
  ios.scheme-name)
    name=$(yq -r '.name' "$json_file")
    [ "$name" != "null" ] || die "expo config has no .name in $json_file"
    printf '%s\n' "$name" | tr -dc 'A-Za-z0-9\n'
    ;;
  *)
    value=$(yq -r ".$key // \"\"" "$json_file")
    [ -n "$value" ] || die "expo config key not found: $key"
    printf '%s\n' "$value"
    ;;
esac
