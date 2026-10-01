#!/usr/bin/env bash
# Run one fastlane lane for the consumer.
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
#
# WORKFLOWS_FASTLANE_DIRECTORY (the `fastlane-directory` input, default
# `fastlane`) is where the Fastfile lives, relative to the consumer root. fastlane
# itself takes no option or variable naming that directory: FastlaneFolder.path
# (fastlane_core/lib/fastlane_core/fastlane_folder.rb) looks for ./fastlane/ or
# ./.fastlane/ under the working directory, and nothing else. So the lane runs
# from the directory that *contains* it, and the directory has to be called
# fastlane or .fastlane - mobile/fastlane works, mobile/lanes cannot. The
# variable is exported resolved, so a verify lane's verify-ios.sh or
# verify-android.sh reads the store metadata from the same directory.
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

fastlane_directory="${WORKFLOWS_FASTLANE_DIRECTORY:-fastlane}"
fastlane_directory="${fastlane_directory%/}"
case "$fastlane_directory" in
  /* | .. | ../* | */.. | */../*)
    die_fix "fastlane-directory is '$fastlane_directory', which is not a directory inside the consumer" \
      "pass a path relative to working-directory, such as fastlane or mobile/fastlane" "expo-or-bare"
    ;;
esac
case "${fastlane_directory##*/}" in
  fastlane | .fastlane) ;;
  *)
    die_fix "fastlane-directory is '$fastlane_directory', but fastlane only finds a directory named fastlane or .fastlane" \
      "rename the directory to fastlane (it may sit anywhere in the repository, such as mobile/fastlane)" "expo-or-bare"
    ;;
esac
[ -d "$root/$fastlane_directory" ] || die_fix "no $fastlane_directory/ in $root (the fastlane-directory input)" \
  "pass the directory that holds your Fastfile as fastlane-directory, relative to working-directory" "expo-or-bare"
lane_root="$(cd "$root/$fastlane_directory/.." && pwd -P)"
export WORKFLOWS_FASTLANE_DIRECTORY="$fastlane_directory"

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

# The Gemfile beside the fastlane directory wins over the consumer root's.
# Named explicitly: bundler would otherwise search upwards from the lane's
# directory and could find a different one.
gemfile="$root/Gemfile"
[ ! -f "$lane_root/Gemfile" ] || gemfile="$lane_root/Gemfile"

group "fastlane $platform $lane"
log "running fastlane from $lane_root (fastlane-directory: $fastlane_directory)"
cd "$lane_root"
if [ -f "$gemfile" ] && command -v bundle >/dev/null 2>&1; then
  BUNDLE_GEMFILE="$gemfile" bundle exec fastlane "$platform" "$lane" "$@"
else
  # No Gemfile means the consumer is not pinning fastlane; a global fastlane is
  # then the only thing that can run, and its absence must be an explicit error
  # rather than a confusing "command not found" in the middle of a release.
  require_cmd fastlane
  log "no Gemfile in $lane_root or $root - running the fastlane on PATH (unpinned)"
  fastlane "$platform" "$lane" "$@"
fi
endgroup
