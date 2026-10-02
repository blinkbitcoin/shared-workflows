#!/bin/bash
# Copy a screenshot/icon/feature-graphic file into the right place under
# fastlane/, choosing the destination from the file's pixel dimensions (and,
# for Android screenshots, an explicit --kind). Never moves the source.
#
# Usage:
#   place-images.sh --platform ios|android [--locale en-US] \
#     [--kind screenshot|icon|feature|phone|seven-inch|ten-inch] \
#     [--force] [--dry-run] <file>...
#
# iOS images always land under fastlane/screenshots/<locale>/. Android
# images always land under fastlane/metadata/android/<locale>/images/ -
# never in a top-level fastlane/metadata/android/images/: supply reads
# <locale>/images/{icon,featureGraphic}.png and
# <locale>/images/<screenshotType>/* (supply/lib/supply/uploader.rb:286,
# 309) and treats every directory directly under metadata/android as a
# locale (:468), so a global images/ dir is both ignored for images and
# pushed as a bogus locale.
#
# --kind chooses the Android screenshot folder explicitly
# (phone|seven-inch|ten-inch); with no --kind, anything that isn't exactly
# 512x512 (icon) or 1024x500 (featureGraphic) defaults to phone. Play has no
# fixed screenshot sizes: 320-3840px per side is the whole constraint, so
# both landscape and tall-portrait screenshots (e.g. 1080x2340) are
# accepted.
#
# Exit codes: 0 ok, 1 an unrecognised size, 2 destination exists without
# --force, 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

# Every WxH pixel pair deliver's Deliver::AppScreenshot::DEVICE_RESOLUTIONS
# table accepts - grepped from the vendored deliver/lib/deliver/
# app_screenshot.rb the same way check-metadata.sh derives it; kept in sync
# with that script's copy by a test that diffs both against the gem file.
IOS_SCREENSHOT_SIZES="1024x748 1024x768 1080x2340 1125x2436 1136x600 1136x640 1170x2532 1179x2556 1206x2622 1242x2208 1242x2688 1260x2736 1280x800 1284x2778 1290x2796 1320x2868 1334x750 1440x900 1488x2266 1536x2008 1536x2048 1640x2360 1668x2224 1668x2388 1668x2420 1920x1080 2048x1496 2048x1536 2048x2732 2064x2752 2208x1242 2224x1668 2266x1488 2340x1080 2360x1640 2388x1668 2420x1668 2436x1125 2532x1170 2556x1179 2560x1600 2622x1206 2688x1242 2732x2048 2736x1260 2752x2064 2778x1284 2796x1290 2868x1320 2880x1800 312x390 368x448 3840x2160 396x484 410x502 416x496 422x514 640x1096 640x1136 640x920 640x960 750x1334 768x1004 768x1024 960x600 960x640"
ALL_KNOWN_SIZES="$IOS_SCREENSHOT_SIZES 1024x500 512x512"

PLATFORM=""
LOCALE="en-US"
KIND=""
FORCE=0
DRY_RUN=0
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      [ $# -ge 2 ] || die_usage "--platform needs a value"
      case "$2" in
        ios | android) : ;;
        *) die_usage "--platform must be ios or android" ;;
      esac
      PLATFORM="$2"
      shift 2
      ;;
    --locale)
      [ $# -ge 2 ] || die_usage "--locale needs a value"
      LOCALE="$2"
      shift 2
      ;;
    --kind)
      [ $# -ge 2 ] || die_usage "--kind needs a value"
      case "$2" in
        screenshot | icon | feature | phone | seven-inch | ten-inch) : ;;
        *) die_usage "--kind must be one of screenshot, icon, feature, phone, seven-inch, ten-inch" ;;
      esac
      KIND="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do FILES+=("$1"); shift; done
      ;;
    -*)
      die_usage "unknown option '$1'"
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

[ -n "$PLATFORM" ] || die_usage "--platform is required"
[ "${#FILES[@]}" -gt 0 ] || die_usage "at least one file is required"

REPO_ROOT="${REPO_ROOT:-$(pwd)}"

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

nearest_size() {
  local w="$1" h="$2" best="" best_dist=999999999 s sw sh dw dh dist
  for s in $ALL_KNOWN_SIZES; do
    sw="${s%x*}"
    sh="${s#*x}"
    dw=$((sw - w))
    [ "$dw" -lt 0 ] && dw=$((-dw))
    dh=$((sh - h))
    [ "$dh" -lt 0 ] && dh=$((-dh))
    dist=$((dw + dh))
    if [ "$dist" -lt "$best_dist" ]; then
      best_dist="$dist"
      best="$s"
    fi
  done
  printf '%s\n' "$best"
}

copy_to() {
  local src="$1" dest="$2"
  if [ -e "$dest" ] && [ "$FORCE" -ne 1 ]; then
    echo "FATAL: $dest already exists (pass --force to overwrite)" >&2
    return 2
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would copy $src -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "copied $src -> $dest"
  return 0
}

next_seq() {
  local dir="$1" max=0 n base
  [ -d "$dir" ] || { echo "01"; return 0; }
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      [0-9][0-9]_*)
        n="${base%%_*}"
        n="${n#0}"
        [ -n "$n" ] || n=0
        [ "$n" -gt "$max" ] && max="$n"
        ;;
    esac
  done
  printf '%02d\n' "$((max + 1))"
}

EXIT_CODE=0

for src in "${FILES[@]}"; do
  [ -f "$src" ] || { echo "FATAL: not found: $src" >&2; EXIT_CODE=64; continue; }
  wh="$(get_wh "$src")" || { echo "FATAL: could not read dimensions of $src" >&2; EXIT_CODE=1; continue; }
  w="${wh%% *}"
  h="${wh##* }"
  size="${w}x${h}"
  base="$(basename "$src")"

  is_known_ios_size=0
  printf ' %s ' "$IOS_SCREENSHOT_SIZES" | grep -q " $size " && is_known_ios_size=1

  dest=""
  if [ "$PLATFORM" = "ios" ]; then
    if [ "$is_known_ios_size" -eq 1 ] && { [ -z "$KIND" ] || [ "$KIND" = "screenshot" ]; }; then
      dir="$REPO_ROOT/${FASTLANE_DIRECTORY:-fastlane}/screenshots/$LOCALE"
      seq="$(next_seq "$dir")"
      dest="$dir/${seq}_${base}"
    fi
  else
    android_base="$REPO_ROOT/${FASTLANE_DIRECTORY:-fastlane}/metadata/android/$LOCALE/images"
    if { [ "$KIND" = "icon" ] || [ -z "$KIND" ]; } && [ "$size" = "512x512" ]; then
      dest="$android_base/icon.png"
    elif { [ "$KIND" = "feature" ] || [ -z "$KIND" ]; } && [ "$size" = "1024x500" ]; then
      dest="$android_base/featureGraphic.png"
    elif [ "$KIND" = "icon" ] || [ "$KIND" = "feature" ]; then
      : # explicit icon/feature kind but wrong size - falls through to refusal below
    elif android_screenshot_legal "$w" "$h"; then
      case "$KIND" in
        seven-inch) subdir="sevenInchScreenshots" ;;
        ten-inch) subdir="tenInchScreenshots" ;;
        phone | screenshot | "") subdir="phoneScreenshots" ;;
        *) subdir="phoneScreenshots" ;;
      esac
      dir="$android_base/$subdir"
      seq="$(next_seq "$dir")"
      dest="$dir/${seq}_${base}"
    fi
  fi

  if [ -z "$dest" ]; then
    nearest="$(nearest_size "$w" "$h")"
    echo "FATAL: $src is ${size} - not a recognised $PLATFORM image size (nearest legal size: $nearest)" >&2
    EXIT_CODE=1
    continue
  fi

  copy_to "$src" "$dest" || EXIT_CODE=$?
done

exit "$EXIT_CODE"
