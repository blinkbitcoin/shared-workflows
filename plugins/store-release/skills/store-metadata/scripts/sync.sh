#!/bin/bash
# Push fastlane/metadata/** (and fastlane/screenshots/** for iOS) to App
# Store Connect and/or Google Play - `bundle exec fastlane <platform>
# sync_metadata`. Never runs the lane without check-metadata.sh passing
# first, and never runs it for real without an explicit --yes.
#
# Usage:
#   sync.sh ios|android|both [--dry-run] [--yes]
#
# Exit codes: 0 the lane(s) succeeded, 2 STORE_METADATA_SYNC_ENABLED is not
# truthy, or check-metadata.sh failed, 64 usage (including a real run with
# no --yes). Otherwise the exit code is the lane's own.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }
die_refused() { echo "FATAL: $*" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_METADATA="$SCRIPT_DIR/check-metadata.sh"

PLATFORM=""
DRY_RUN=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    ios | android | both)
      [ -z "$PLATFORM" ] || die_usage "platform given twice"
      PLATFORM="$1"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

[ -n "$PLATFORM" ] || die_usage "one of ios, android or both is required"

case "${STORE_METADATA_SYNC_ENABLED:-}" in
  true | 1 | yes) : ;;
  *)
    die_refused "STORE_METADATA_SYNC_ENABLED is not set - set STORE_METADATA_SYNC_ENABLED=true" \
      "before a lane may write the public store page (see the app's release runbook)"
    ;;
esac

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
# fastlane runs from the directory that contains the app's fastlane directory.
FASTLANE_DIRECTORY="${FASTLANE_DIRECTORY:-fastlane}"
LANE_DIR="$(dirname "$REPO_ROOT/$FASTLANE_DIRECTORY")"

run_check() {
  local platform="$1"
  REPO_ROOT="$REPO_ROOT" FASTLANE_DIRECTORY="$FASTLANE_DIRECTORY" "$CHECK_METADATA" --platform "$platform"
}

if [ "$PLATFORM" = "both" ]; then
  run_check ios || die_refused "check-metadata.sh --platform ios failed - fix the listed issues before syncing"
  run_check android || die_refused "check-metadata.sh --platform android failed - fix the listed issues before syncing"
else
  run_check "$PLATFORM" || die_refused "check-metadata.sh --platform $PLATFORM failed - fix the listed issues before syncing"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  export DRY_RUN=1
else
  [ "$YES" -eq 1 ] || die_usage "a real (non---dry-run) sync needs --yes"
fi

run_lane() {
  local platform="$1"
  (cd "$LANE_DIR" && bundle exec fastlane "$platform" sync_metadata)
}

EXIT_CODE=0
if [ "$PLATFORM" = "both" ]; then
  run_lane ios || EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 0 ]; then
    run_lane android || EXIT_CODE=$?
  fi
else
  run_lane "$PLATFORM" || EXIT_CODE=$?
fi

exit "$EXIT_CODE"
