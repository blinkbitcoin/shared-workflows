#!/bin/bash
# Create the empty file tree that `deliver`/`supply` read metadata and
# screenshots from - iOS under fastlane/metadata/ios and
# fastlane/screenshots, Android under fastlane/metadata/android/<locale>
# (including its images/ - supply reads <locale>/images/{icon,
# featureGraphic}.png and <locale>/images/<screenshotType>/*, and treats
# every directory directly under metadata/android as a locale, so Android
# images are always scaffolded per-locale, never in a top-level images/).
# Every created file is empty; it exists purely so it can be found, filled
# in, and picked up by check-metadata.sh. An existing file is never
# touched, and never blanked - re-running is idempotent whether or not
# --force is given.
#
# Usage:
#   scaffold.sh [--locale en-US] [--platform ios|android|both] [--from-console] [--force]
#
# --force does not change what gets written (existing files are still
# never touched or truncated); it is the acknowledgement required to
# scaffold at all when the target tree already holds a non-empty file - a
# guard against running this against a live, already-filled-in checkout by
# accident. Combined with --from-console (which mutates the tree itself,
# via the pull lane) it is refused as ambiguous.
#
# --from-console runs `bundle exec fastlane <platform> pull_metadata` first
# (the lane itself writes the tree - this does not merge anything) and then
# reports a diff of what changed. It does not skip the normal create-if-
# missing pass, so a hand-written file the pull didn't touch is still left
# alone.
#
# Category files (primary_category.txt etc.) are deliberately NOT created -
# see docs/release-runbook.md "Categories are console-only until you create
# the files."
#
# Exit codes: 0 ok, 2 not in a repo with fastlane/, or the tree already has
# content and --force was not given, 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

LOCALE="en-US"
PLATFORM="both"
FROM_CONSOLE=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --locale)
      [ $# -ge 2 ] || die_usage "--locale needs a value"
      LOCALE="$2"
      shift 2
      ;;
    --platform)
      [ $# -ge 2 ] || die_usage "--platform needs a value"
      case "$2" in
        ios | android | both) : ;;
        *) die_usage "--platform must be ios, android or both" ;;
      esac
      PLATFORM="$2"
      shift 2
      ;;
    --from-console)
      FROM_CONSOLE=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

[ "$FROM_CONSOLE" -eq 1 ] && [ "$FORCE" -eq 1 ] && die_usage "--force and --from-console together are ambiguous - run them separately"

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
# FASTLANE_DIRECTORY: where the app keeps its fastlane directory, relative to the
# repository root. fastlane itself runs from the directory that contains it.
FASTLANE_DIRECTORY="${FASTLANE_DIRECTORY:-fastlane}"
FASTLANE_DIR="$REPO_ROOT/$FASTLANE_DIRECTORY"
LANE_DIR="$(dirname "$FASTLANE_DIR")"
[ -d "$FASTLANE_DIR" ] || {
  echo "FATAL: no $FASTLANE_DIRECTORY/ directory under $REPO_ROOT - run this from the app repo" >&2
  exit 2
}

ios_paths() {
  echo "metadata/ios/copyright.txt"
  for name in name subtitle description keywords promotional_text release_notes support_url marketing_url privacy_url; do
    echo "metadata/ios/$LOCALE/$name.txt"
  done
  for name in first_name last_name phone_number email_address demo_user demo_password notes; do
    echo "metadata/ios/review_information/$name.txt"
  done
  echo "screenshots/$LOCALE/.gitkeep"
}

android_paths() {
  for name in title short_description full_description video; do
    echo "metadata/android/$LOCALE/$name.txt"
  done
  echo "metadata/android/$LOCALE/changelogs/default.txt"
  echo "metadata/android/$LOCALE/images/.gitkeep"
  echo "metadata/android/$LOCALE/images/phoneScreenshots/.gitkeep"
  echo "metadata/android/$LOCALE/images/sevenInchScreenshots/.gitkeep"
  echo "metadata/android/$LOCALE/images/tenInchScreenshots/.gitkeep"
}

TARGETS=()
while IFS= read -r p; do TARGETS+=("$p"); done < <(
  { [ "$PLATFORM" = "android" ] || ios_paths; [ "$PLATFORM" = "ios" ] || android_paths; }
)

# Guard: refuse to proceed (without --force) if any target file already
# holds content. An empty/missing tree, or one already scaffolded by a
# prior run (files exist but stay empty), needs no --force. --from-console
# has its own consent (it runs the pull lane) and never blanks anything
# either, so it is exempt from this guard.
HAS_CONTENT=0
for p in "${TARGETS[@]}"; do
  full="$FASTLANE_DIR/$p"
  [ -s "$full" ] && HAS_CONTENT=1 && break
done
if [ "$HAS_CONTENT" -eq 1 ] && [ "$FORCE" -ne 1 ] && [ "$FROM_CONSOLE" -ne 1 ]; then
  echo "FATAL: $FASTLANE_DIRECTORY/metadata (or $FASTLANE_DIRECTORY/screenshots) already has filled-in content - pass --force to scaffold onto it anyway (nothing existing is ever touched or blanked)" >&2
  exit 2
fi

if [ "$FROM_CONSOLE" -eq 1 ]; then
  run_pull() {
    local platform="$1"
    echo "== bundle exec fastlane $platform pull_metadata"
    (cd "$LANE_DIR" && bundle exec fastlane "$platform" pull_metadata)
  }
  [ "$PLATFORM" = "android" ] || run_pull ios
  [ "$PLATFORM" = "ios" ] || run_pull android

  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "== diff after pull_metadata"
    git -C "$REPO_ROOT" status --short -- "$FASTLANE_DIR/metadata" "$FASTLANE_DIR/screenshots"
  fi
fi

CREATED=0
for p in "${TARGETS[@]}"; do
  full="$FASTLANE_DIR/$p"
  mkdir -p "$(dirname "$full")"
  [ -f "$full" ] && continue
  : >"$full"
  CREATED=$((CREATED + 1))
done

echo "scaffolded $CREATED file(s) for locale $LOCALE (platform: $PLATFORM)"
echo "note: category files (primary_category.txt, secondary_category.txt) are console-only and were not created;" \
     "adding primary_category.txt also requires the four sub-category files" \
     "(primary_first_sub_category.txt, primary_second_sub_category.txt, secondary_first_sub_category.txt, secondary_second_sub_category.txt)"
exit 0
