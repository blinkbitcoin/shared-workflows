#!/bin/bash
# Write fastlane/metadata/ios/app_rating_config.json - the file sync_metadata
# uploads as the App Store age rating declaration. Keys are the camelCase
# form of vendor/.../spaceship/lib/spaceship/connect_api/models/
# age_rating_declaration.rb's attr_accessor list, minus
# developerAgeRatingInfoUrl (no safe default) and gamblingAndContests
# (deprecated) - matching the shipped file exactly. A test derives the
# expected key list from that gem file itself.
#
# Usage:
#   age-rating.sh [--out fastlane/metadata/ios/app_rating_config.json] --list-keys
#   age-rating.sh [--out <path>] --set key=value [key=value...]
#   age-rating.sh [--out <path>] --from-answers <file>
#
# --from-answers reads the same key=value pairs, one per line (blank lines
# and #-comments ignored).
#
# Exit codes: 0 ok, 1 an otherwise-valid set is incomplete, 64 usage
# (unknown key or a value that fails validation for its key's type).

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

# Order matches the gem file's attr_accessor declaration order.
RATING_KEYS="alcoholTobaccoOrDrugUseOrReferences contests gamblingSimulated gunsOrOtherWeapons horrorOrFearThemes matureOrSuggestiveThemes medicalOrTreatmentInformation profanityOrCrudeHumor sexualContentGraphicAndNudity sexualContentOrNudity violenceCartoonOrFantasy violenceRealisticProlongedGraphicOrSadistic violenceRealistic"
BOOLEAN_KEYS="advertising ageAssurance gambling healthOrWellnessTopics lootBox messagingAndChat parentalControls socialMedia socialMediaAgeRestricted unrestrictedWebAccess userGeneratedContent"
ENUM_KEYS="ageRatingOverrideV2 koreaAgeRatingOverride kidsAgeBand"

ALL_KEYS="$RATING_KEYS $BOOLEAN_KEYS $ENUM_KEYS"

RATING_VALUES="NONE INFREQUENT_OR_MILD FREQUENT_OR_INTENSE"
AGE_RATING_OVERRIDE_VALUES="NONE NINE_PLUS THIRTEEN_PLUS SIXTEEN_PLUS EIGHTEEN_PLUS UNRATED"
KOREA_AGE_RATING_VALUES="NONE FIFTEEN_PLUS NINETEEN_PLUS"
KIDS_AGE_BAND_VALUES="null FIVE_AND_UNDER SIX_TO_EIGHT NINE_TO_ELEVEN"

is_in() {
  local needle="$1" hay="$2" x
  for x in $hay; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

key_kind() {
  local key="$1"
  is_in "$key" "$RATING_KEYS" && { echo "rating"; return 0; }
  is_in "$key" "$BOOLEAN_KEYS" && { echo "boolean"; return 0; }
  case "$key" in
    ageRatingOverrideV2) echo "age_rating_override"; return 0 ;;
    koreaAgeRatingOverride) echo "korea_age_rating"; return 0 ;;
    kidsAgeBand) echo "kids_age_band"; return 0 ;;
  esac
  echo ""
  return 1
}

validate_value() {
  local key="$1" value="$2" kind
  kind="$(key_kind "$key")" || return 1
  case "$kind" in
    rating) is_in "$value" "$RATING_VALUES" ;;
    boolean) [ "$value" = "true" ] || [ "$value" = "false" ] ;;
    age_rating_override) is_in "$value" "$AGE_RATING_OVERRIDE_VALUES" ;;
    korea_age_rating) is_in "$value" "$KOREA_AGE_RATING_VALUES" ;;
    kids_age_band) is_in "$value" "$KIDS_AGE_BAND_VALUES" ;;
    *) return 1 ;;
  esac
}

OUT="${FASTLANE_DIRECTORY:-fastlane}/metadata/ios/app_rating_config.json"
MODE=""
FROM_ANSWERS=""
SET_PAIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || die_usage "--out needs a path"
      OUT="$2"
      shift 2
      ;;
    --list-keys)
      MODE="list-keys"
      shift
      ;;
    --set)
      MODE="set"
      shift
      ;;
    --from-answers)
      [ $# -ge 2 ] || die_usage "--from-answers needs a path"
      MODE="from-answers"
      FROM_ANSWERS="$2"
      shift 2
      ;;
    *=*)
      [ "$MODE" = "set" ] || die_usage "key=value pairs only follow --set"
      SET_PAIRS+=("$1")
      shift
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

[ -n "$MODE" ] || die_usage "one of --list-keys, --set or --from-answers is required"

if [ "$MODE" = "list-keys" ]; then
  for k in $ALL_KEYS; do echo "$k"; done
  exit 0
fi

if [ "$MODE" = "from-answers" ]; then
  [ -f "$FROM_ANSWERS" ] || die_usage "--from-answers file not found: $FROM_ANSWERS"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    SET_PAIRS+=("$line")
  done <"$FROM_ANSWERS"
fi

# Parallel arrays (bash 3.2 has no associative arrays).
ANSWER_KEYS=()
ANSWER_VALUES=()

for pair in "${SET_PAIRS[@]+"${SET_PAIRS[@]}"}"; do
  key="${pair%%=*}"
  value="${pair#*=}"
  [ "$key" != "$pair" ] || die_usage "malformed key=value pair: $pair"
  key_kind "$key" >/dev/null || die_usage "unknown age-rating key: '$key' (see --list-keys)"
  validate_value "$key" "$value" || die_usage "'$value' is not a valid value for '$key'"
  for i in "${!ANSWER_KEYS[@]}"; do
    if [ "${ANSWER_KEYS[$i]}" = "$key" ]; then
      ANSWER_VALUES[i]="$value"
      key=""
      break
    fi
  done
  [ -z "$key" ] || { ANSWER_KEYS+=("$key"); ANSWER_VALUES+=("$value"); }
done

MISSING=()
for k in $ALL_KEYS; do
  found=0
  for existing in "${ANSWER_KEYS[@]+"${ANSWER_KEYS[@]}"}"; do
    [ "$existing" = "$k" ] && { found=1; break; }
  done
  [ "$found" -eq 1 ] || MISSING+=("$k")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "FATAL: age-rating set is incomplete, unanswered:" >&2
  for k in "${MISSING[@]}"; do echo "  $k" >&2; done
  exit 1
fi

# --- write valid JSON, one key per line, in ALL_KEYS order ------------------
mkdir -p "$(dirname "$OUT")"
{
  echo "{"
  n=0
  total="${#ANSWER_KEYS[@]}"
  for k in $ALL_KEYS; do
    for i in "${!ANSWER_KEYS[@]}"; do
      if [ "${ANSWER_KEYS[$i]}" = "$k" ]; then
        v="${ANSWER_VALUES[$i]}"
        n=$((n + 1))
        comma=","
        [ "$n" -eq "$total" ] && comma=""
        kind="$(key_kind "$k")"
        case "$kind" in
          boolean) printf '  "%s": %s%s\n' "$k" "$v" "$comma" ;;
          kids_age_band)
            if [ "$v" = "null" ]; then
              printf '  "%s": null%s\n' "$k" "$comma"
            else
              printf '  "%s": "%s"%s\n' "$k" "$v" "$comma"
            fi
            ;;
          *) printf '  "%s": "%s"%s\n' "$k" "$v" "$comma" ;;
        esac
        break
      fi
    done
  done
  echo "}"
} >"$OUT"

echo "wrote $OUT"
exit 0
