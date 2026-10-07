#!/bin/bash
# The gate: everything sync.sh refuses to push unless this passes first.
# Checks fastlane/metadata/** (and fastlane/screenshots/** for iOS) for the
# template placeholder, missing/empty required fields, length limits,
# keyword/URL shape, category ids, review-info completeness and image
# sizes.
#
# Usage:
#   check-metadata.sh [--platform ios|android|both] [--locale en-US] [--fix-safe]
#
# --fix-safe normalises trailing whitespace and a missing final newline in
# every .txt file under fastlane/metadata, and nothing else, before the
# checks run.
#
# One "path: reason" line per offender on stdout/stderr; exit 1 if any.
# Exit codes: 0 ok, 1 violations found, 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

# The template ships prose that says this; shipping it to App Review or Play
# is worse than failing the lane. Must equal METADATA_PLACEHOLDER in
# fastlane/lanes/shared.rb - a test asserts that.
PLACEHOLDER='Replace this text'

# Modern App Store Connect category ids - the "[A-Z_]+" constants in the
# vendored spaceship app_category.rb. A test asserts this equals that file's
# ids exactly.
CATEGORY_IDS="BOOKS BUSINESS DEVELOPER_TOOLS EDUCATION ENTERTAINMENT FINANCE FOOD_AND_DRINK GAMES GAMES_ACTION GAMES_ADVENTURE GAMES_BOARD GAMES_CARD GAMES_CASINO GAMES_CASUAL GAMES_FAMILY GAMES_MUSIC GAMES_PUZZLE GAMES_RACING GAMES_ROLE_PLAYING GAMES_SIMULATION GAMES_SPORTS GAMES_STRATEGY GAMES_TRIVIA GAMES_WORD GRAPHICS_AND_DESIGN HEALTH_AND_FITNESS LIFESTYLE MAGAZINES_AND_NEWSPAPERS MEDICAL MUSIC NAVIGATION NEWS PHOTO_AND_VIDEO PRODUCTIVITY REFERENCE SHOPPING SOCIAL_NETWORKING SPORTS STICKERS STICKERS_ANIMALS STICKERS_ART STICKERS_CELEBRATIONS STICKERS_CELEBRITIES STICKERS_CHARACTERS STICKERS_EATING_AND_DRINKING STICKERS_EMOJI_AND_EXPRESSIONS STICKERS_FASHION STICKERS_GAMING STICKERS_KIDS_AND_FAMILY STICKERS_MOVIES_AND_TV STICKERS_MUSIC STICKERS_PEOPLE STICKERS_PLACES_AND_OBJECTS STICKERS_SPORTS_AND_ACTIVITIES TRAVEL UTILITIES WEATHER"

# Every WxH pixel pair deliver's own Deliver::AppScreenshot::DEVICE_RESOLUTIONS
# table (plus its CONFLICTING_RESOLUTIONS list, a subset) accepts, grepped
# with `[0-9]+, *[0-9]+` from the vendored deliver/lib/deliver/
# app_screenshot.rb - the same way CATEGORY_IDS is grepped from
# app_category.rb. A test asserts this equals that file's set exactly.
IOS_SCREENSHOT_SIZES="1024x748 1024x768 1080x2340 1125x2436 1136x600 1136x640 1170x2532 1179x2556 1206x2622 1242x2208 1242x2688 1260x2736 1280x800 1284x2778 1290x2796 1320x2868 1334x750 1440x900 1488x2266 1536x2008 1536x2048 1640x2360 1668x2224 1668x2388 1668x2420 1920x1080 2048x1496 2048x1536 2048x2732 2064x2752 2208x1242 2224x1668 2266x1488 2340x1080 2360x1640 2388x1668 2420x1668 2436x1125 2532x1170 2556x1179 2560x1600 2622x1206 2688x1242 2732x2048 2736x1260 2752x2064 2778x1284 2796x1290 2868x1320 2880x1800 312x390 368x448 3840x2160 396x484 410x502 416x496 422x514 640x1096 640x1136 640x920 640x960 750x1334 768x1004 768x1024 960x600 960x640"

PLATFORM="both"
LOCALE=""
FIX_SAFE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      [ $# -ge 2 ] || die_usage "--platform needs a value"
      case "$2" in
        ios | android | both) : ;;
        *) die_usage "--platform must be ios, android or both" ;;
      esac
      PLATFORM="$2"
      shift 2
      ;;
    --locale)
      [ $# -ge 2 ] || die_usage "--locale needs a value"
      LOCALE="$2"
      shift 2
      ;;
    --fix-safe)
      FIX_SAFE=1
      shift
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
# FASTLANE_DIRECTORY: where the app keeps its fastlane directory, relative to the
# repository root (the `fastlane-directory` input of the release workflows).
FASTLANE_DIRECTORY="${FASTLANE_DIRECTORY:-fastlane}"
METADATA_DIR="$REPO_ROOT/$FASTLANE_DIRECTORY/metadata"
SCREENSHOTS_DIR="$REPO_ROOT/$FASTLANE_DIRECTORY/screenshots"
[ -d "$METADATA_DIR" ] || die_usage "no $FASTLANE_DIRECTORY/metadata directory under $REPO_ROOT"

VIOLATIONS=()
add_violation() { VIOLATIONS+=("$1: $2"); }

rel() { printf '%s\n' "${1#"$REPO_ROOT"/}"; }

# --- --fix-safe --------------------------------------------------------------
if [ "$FIX_SAFE" -eq 1 ]; then
  while IFS= read -r -d '' f; do
    tmp="$f.fixsafe.tmp"
    sed -e 's/[[:space:]]*$//' "$f" >"$tmp"
    # Ensure exactly one trailing newline.
    if [ -s "$tmp" ]; then
      printf '%s\n' "$(cat "$tmp")" >"$tmp.2"
      mv "$tmp.2" "$tmp"
    fi
    if ! cmp -s "$f" "$tmp"; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  done < <(find "$METADATA_DIR" -name '*.txt' -print0)
fi

# --- locale discovery ----------------------------------------------------
# `supply` enumerates every directory under metadata/android as a locale
# (supply/lib/supply/uploader.rb:468), so `images` - which must never exist
# as a top-level directory there (see check_android) - is excluded here too,
# defensively, alongside iOS's own non-locale special directories.
locales_for() {
  local platform_dir="$1"
  if [ -n "$LOCALE" ]; then
    echo "$LOCALE"
    return 0
  fi
  [ -d "$platform_dir" ] || return 0
  find "$platform_dir" -mindepth 1 -maxdepth 1 -type d ! -name 'review_information' \
    ! -name 'trade_representative_contact_information' ! -name 'app_clip_review_information' \
    ! -name 'images' \
    -exec basename {} \; | sort
}

# --- helpers ---------------------------------------------------------------
# Counts Unicode code points, one trailing newline stripped (a file saved
# "at the limit" with an editor's final newline must not read as over by
# one). Uses node rather than `wc -m`, which under a "C"/POSIX locale counts
# bytes, not code points, and would over-count anything outside ASCII.
#
# Every .txt under the metadata tree is counted once, up front, by one node
# (CHAR_COUNTS, "<path><TAB><count>" lines): a node per file was most of
# this script's time. A path not in it is counted on its own.
CHAR_COUNTS=$'\n'
if [ -d "$METADATA_DIR" ]; then
  CHAR_COUNTS+="$(find "$METADATA_DIR" -name '*.txt' -print0 | node -e '
    const fs = require("fs");
    const paths = fs.readFileSync(0, "utf8").split("\0").filter((p) => p && !/[\t\n]/.test(p));
    for (const p of paths) {
      try {
        const s = fs.readFileSync(p, "utf8").replace(/\n$/, "");
        process.stdout.write(p + "\t" + Array.from(s).length + "\n");
      } catch (e) {}
    }
  ')"$'\n'
fi
char_count() {
  local rest="${CHAR_COUNTS#*$'\n'"$1"$'\t'}"
  if [ "$rest" != "$CHAR_COUNTS" ]; then
    printf '%s' "${rest%%$'\n'*}"
    return 0
  fi
  node -e '
    const fs = require("fs");
    let s = fs.readFileSync(process.argv[1], "utf8");
    s = s.replace(/\n$/, "");
    process.stdout.write(String(Array.from(s).length));
  ' "$1"
}

check_no_placeholder() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' f; do
    if grep -qF "$PLACEHOLDER" "$f"; then
      add_violation "$(rel "$f")" "contains the template placeholder text"
    fi
  done < <(find "$dir" -name '*.txt' -print0)
}

check_limit() {
  local file="$1" limit="$2" label="$3"
  [ -f "$file" ] || return 0
  local n
  n="$(char_count "$file")"
  if [ "$n" -gt "$limit" ]; then
    add_violation "$(rel "$file")" "$label is $n characters, limit is $limit"
  fi
}

check_exists() {
  local file="$1"
  [ -f "$file" ] || add_violation "$(rel "$file")" "missing"
}

# A file holding only whitespace counts as empty - it satisfies -s but
# carries nothing deliver/supply would show.
is_blank() {
  local file="$1"
  [ -s "$file" ] || return 0
  [ -z "$(tr -d '[:space:]' <"$file")" ]
}

check_not_empty() {
  local file="$1"
  [ -f "$file" ] || return 0
  if is_blank "$file"; then
    add_violation "$(rel "$file")" "is empty"
  fi
}

get_wh() {
  local file="$1"
  if command -v sips >/dev/null 2>&1; then
    local w h
    w="$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth:/{print $2}')"
    h="$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight:/{print $2}')"
    [ -n "$w" ] && [ -n "$h" ] || return 1
    printf '%s %s\n' "$w" "$h"
    return 0
  fi
  if command -v magick >/dev/null 2>&1; then
    magick identify -format '%w %h' "$file" 2>/dev/null
    return $?
  fi
  if command -v identify >/dev/null 2>&1; then
    identify -format '%w %h' "$file" 2>/dev/null
    return $?
  fi
  return 2
}

# Play has no fixed screenshot sizes: 320-3840px per side is the whole
# constraint (a common tall phone shot such as 1080x2340 - ratio ~2.17:1 -
# must still pass, so no additional aspect-ratio bound is enforced here).
android_screenshot_legal() {
  local w="$1" h="$2"
  [ "$w" -ge 320 ] && [ "$w" -le 3840 ] || return 1
  [ "$h" -ge 320 ] && [ "$h" -le 3840 ] || return 1
  return 0
}

HAVE_IMAGE_TOOL=1
if ! command -v sips >/dev/null 2>&1 && ! command -v magick >/dev/null 2>&1 && ! command -v identify >/dev/null 2>&1; then
  HAVE_IMAGE_TOOL=0
fi

# --- iOS ---------------------------------------------------------------------
check_ios() {
  local ios_dir="$METADATA_DIR/ios"
  [ -d "$ios_dir" ] || return 0
  check_no_placeholder "$ios_dir"
  check_exists "$ios_dir/copyright.txt"

  local loc
  while IFS= read -r loc; do
    [ -n "$loc" ] || continue
    local base="$ios_dir/$loc"
    [ -d "$base" ] || continue

    for f in name subtitle description keywords promotional_text release_notes support_url marketing_url privacy_url; do
      check_exists "$base/$f.txt"
      check_not_empty "$base/$f.txt"
    done
    check_limit "$base/name.txt" 30 "name"
    check_limit "$base/subtitle.txt" 30 "subtitle"
    check_limit "$base/keywords.txt" 100 "keywords"
    check_limit "$base/promotional_text.txt" 170 "promotional_text"
    check_limit "$base/description.txt" 4000 "description"
    check_limit "$base/release_notes.txt" 4000 "release_notes"

    if [ -f "$base/keywords.txt" ] && grep -qF ', ' "$base/keywords.txt"; then
      add_violation "$(rel "$base/keywords.txt")" "keywords must be comma-separated without a space after the comma"
    fi

    for f in support_url marketing_url privacy_url; do
      local uf="$base/$f.txt"
      [ -f "$uf" ] && [ -s "$uf" ] || continue
      local url
      url="$(cat "$uf")"
      case "$url" in
        https://*) : ;;
        *) add_violation "$(rel "$uf")" "must start with https://" ;;
      esac
      case "$url" in
        *example.com*) add_violation "$(rel "$uf")" "must not point at example.com" ;;
      esac
    done
  done < <(locales_for "$ios_dir")

  # review_information: all-or-nothing.
  local ri="$ios_dir/review_information"
  if [ -d "$ri" ]; then
    # Counted against the fixed seven names, not against the files that
    # happen to exist: with demo_password.txt deleted, counting only
    # existing files reads six-of-six as "all filled" and lets a
    # half-filled review contact through.
    local total=0 nonempty=0 f
    for f in first_name last_name phone_number email_address demo_user demo_password notes; do
      total=$((total + 1))
      if [ -f "$ri/$f.txt" ] && [ -s "$ri/$f.txt" ]; then
        nonempty=$((nonempty + 1))
      fi
    done
    if [ "$nonempty" -gt 0 ] && [ "$nonempty" -lt "$total" ]; then
      add_violation "$(rel "$ri")" "review_information is partially filled - all fields or none"
    fi
  fi

  # Category ids, when present.
  local primary="$ios_dir/primary_category.txt" secondary="$ios_dir/secondary_category.txt"
  for cf in "$primary" "$secondary"; do
    [ -f "$cf" ] && [ -s "$cf" ] || continue
    local id
    id="$(cat "$cf")"
    local found=0 c
    for c in $CATEGORY_IDS; do [ "$c" = "$id" ] && { found=1; break; }; done
    if [ "$found" -ne 1 ]; then
      add_violation "$(rel "$cf")" "'$id' is not a current category id (try e.g. UTILITIES)"
    fi
  done
  if [ -f "$primary" ]; then
    for sub in primary_first_sub_category primary_second_sub_category secondary_first_sub_category secondary_second_sub_category; do
      [ -f "$ios_dir/$sub.txt" ] || add_violation "$(rel "$ios_dir/$sub.txt")" "missing - required whenever primary_category.txt exists (may be empty)"
    done
  fi

  # Screenshots.
  local sdir loc2
  while IFS= read -r loc2; do
    [ -n "$loc2" ] || continue
    sdir="$SCREENSHOTS_DIR/$loc2"
    [ -d "$sdir" ] || continue
    [ "$HAVE_IMAGE_TOOL" -eq 1 ] || continue
    local img
    while IFS= read -r -d '' img; do
      case "$(basename "$img")" in .gitkeep) continue ;; esac
      local wh w h
      wh="$(get_wh "$img")" || { add_violation "$(rel "$img")" "could not read image dimensions"; continue; }
      w="${wh%% *}"
      h="${wh##* }"
      local match=0 s
      for s in $IOS_SCREENSHOT_SIZES; do
        [ "$s" = "${w}x${h}" ] && { match=1; break; }
      done
      [ "$match" -eq 1 ] || add_violation "$(rel "$img")" "${w}x${h} is not a known App Store screenshot size"
    done < <(find "$sdir" -maxdepth 1 -type f -print0)
  done < <(if [ -n "$LOCALE" ]; then echo "$LOCALE"; elif [ -d "$SCREENSHOTS_DIR" ]; then find "$SCREENSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort; fi)
}

# --- Android -------------------------------------------------------------
check_android() {
  local android_dir="$METADATA_DIR/android"
  [ -d "$android_dir" ] || return 0
  check_no_placeholder "$android_dir"

  # supply reads <locale>/images/{icon,featureGraphic}.png and
  # <locale>/images/<screenshotType>/* (supply/lib/supply/uploader.rb:286,
  # 309) and enumerates every directory under metadata/android as a locale
  # (:468) - a top-level images/ here is both ignored for images and pushed
  # as a bogus locale named "images".
  if [ -d "$android_dir/images" ]; then
    add_violation "$(rel "$android_dir/images")" "must not exist - Android images live under <locale>/images/, not a top-level images/ (supply enumerates every directory under metadata/android as a locale)"
  fi

  local loc
  while IFS= read -r loc; do
    [ -n "$loc" ] || continue
    local base="$android_dir/$loc"
    [ -d "$base" ] || continue

    for f in title short_description full_description video; do
      check_exists "$base/$f.txt"
    done
    check_not_empty "$base/title.txt"
    check_not_empty "$base/short_description.txt"
    check_not_empty "$base/full_description.txt"
    # video.txt may be empty.
    check_limit "$base/title.txt" 30 "title"
    check_limit "$base/short_description.txt" 80 "short_description"
    check_limit "$base/full_description.txt" 4000 "full_description"
    check_exists "$base/changelogs/default.txt"
    [ -f "$base/changelogs/default.txt" ] && check_limit "$base/changelogs/default.txt" 500 "changelog"

    [ "$HAVE_IMAGE_TOOL" -eq 1 ] || continue

    local icon="$base/images/icon.png"
    if [ -f "$icon" ]; then
      local wh
      wh="$(get_wh "$icon")" && {
        [ "$wh" = "512 512" ] || add_violation "$(rel "$icon")" "must be 512x512, got ${wh% *}x${wh#* }"
      }
    fi
    local feature="$base/images/featureGraphic.png"
    if [ -f "$feature" ]; then
      local wh
      wh="$(get_wh "$feature")" && {
        [ "$wh" = "1024 500" ] || add_violation "$(rel "$feature")" "must be 1024x500, got ${wh% *}x${wh#* }"
      }
    fi
    local phone_dir="$base/images/phoneScreenshots"
    if [ -d "$phone_dir" ]; then
      local count=0 img
      while IFS= read -r -d '' img; do
        case "$(basename "$img")" in .gitkeep) continue ;; esac
        count=$((count + 1))
        local wh w h
        wh="$(get_wh "$img")" || { add_violation "$(rel "$img")" "could not read image dimensions"; continue; }
        w="${wh%% *}"
        h="${wh##* }"
        android_screenshot_legal "$w" "$h" || add_violation "$(rel "$img")" "${w}x${h} is outside the 320-3840px range"
      done < <(find "$phone_dir" -maxdepth 1 -type f -print0)
      if [ "$count" -gt 0 ] && { [ "$count" -lt 2 ] || [ "$count" -gt 8 ]; }; then
        add_violation "$(rel "$phone_dir")" "has $count screenshot(s), needs 2-8"
      fi
    fi
  done < <(locales_for "$android_dir")
}

[ "$PLATFORM" = "android" ] || check_ios
[ "$PLATFORM" = "ios" ] || check_android

if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
  for v in "${VIOLATIONS[@]}"; do
    echo "$v"
  done
  exit 1
fi

echo "check-metadata: clean (platform: $PLATFORM)"
exit 0
