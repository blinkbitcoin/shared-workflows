#!/usr/bin/env bash
# Run one fastlane lane in the consumer root.
#
# Usage: fastlane.sh PLATFORM LANE [key:value ...]
#   fastlane.sh ios build
#   fastlane.sh android rollout percentage:0.1
#
# $LANE_ARGS adds the same key:value pairs from the environment. That exists so
# a workflow can forward a caller-supplied argument list without an unquoted
# expansion in its `run:` line (which shellcheck rightly rejects).
#
# Lane names (the consumer's Fastfile must define exactly these):
#   ios     build verify upload_internal promote_beta release_production phased upload_symbols
#   android build verify upload_internal promote_beta release_production rollout halt
#
# The lanes read their inputs from the environment - APP_VERSION,
# APP_BUILD_NUMBER, STORE_NOTES_FILE, STORE_NOTES_JSON, IOS_BUNDLE_ID,
# IOS_SCHEME, ANDROID_PACKAGE, BUILD_INFO_FILE, WORKFLOWS_OUTPUT_DIR plus the
# credentials decode-secrets.sh materialised - so this wrapper only fixes up
# the path-valued ones and passes the key:value pairs through verbatim.
#
# fastlane runs a lane with its working directory set to `fastlane/`, not to the
# project root, so every path handed to a lane has to be absolute: a relative
# one silently resolves one directory too deep and the lane reads (or writes)
# the wrong file. Every path variable is absolutised here rather than at each
# call site, so a caller cannot get it wrong.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"

platform="$(workflows_release_platform "${1:-}")"
shift
lane="${1:?usage: fastlane.sh PLATFORM LANE [key:value ...]}"
shift

args=("$@")
if [ -n "${LANE_ARGS:-}" ]; then
  read -r -a extra <<< "$LANE_ARGS"
  args+=("${extra[@]}")
fi
set -- "${args[@]+"${args[@]}"}"

root="$(consumer_root)"
cd "$root"

# absolutise VAR... - rewrite each set variable to an absolute path, resolving a
# relative one against the consumer root.
absolutise() {
  local var value
  for var in "$@"; do
    value="${!var:-}"
    [ -n "$value" ] || continue
    case "$value" in
      /*) ;;
      *) value="$root/$value" ;;
    esac
    export "$var=$value"
    log "$var=$value"
  done
}

mkdir -p "$WORKFLOWS_OUTPUT_DIR"
export WORKFLOWS_OUTPUT_DIR
absolutise WORKFLOWS_OUTPUT_DIR BUILD_INFO_FILE STORE_NOTES_FILE STORE_NOTES_JSON \
  ANDROID_UPLOAD_KEYSTORE_PATH PLAY_SERVICE_ACCOUNT_JSON_PATH ASC_KEY_P8_PATH BUNDLETOOL_JAR

group "fastlane $platform $lane"
if [ -f "$root/Gemfile" ] && command -v bundle >/dev/null 2>&1; then
  bundle exec fastlane "$platform" "$lane" "$@"
else
  # No Gemfile means the consumer is not pinning fastlane; a global fastlane is
  # then the only thing that can run, and its absence must be an explicit error
  # rather than a confusing "command not found" in the middle of a release.
  require_cmd fastlane
  log "no Gemfile in $root - running the fastlane on PATH (unpinned)"
  fastlane "$platform" "$lane" "$@"
fi
endgroup
