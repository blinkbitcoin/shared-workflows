#!/bin/bash
# Print the click-path block for one store-console step (the `apple-*`,
# `google-*` and `huawei-*` ids from `store-setup/scripts/state.sh
# --list-steps`), with the
# `Enter:`/`Take away:` values resolved where a repo-local source exists:
# a `gh variable`, a `fastlane/metadata/**` file, `state.facts.<key>`, or
# `package.json`'s `name`. Falls back to `<ask the human>` when no source is
# available.
#
# Usage:
#   console-step.sh --list
#   console-step.sh <id> [--format text|json] [--repo owner/name]
#
#   STORE_SETUP_DIR   defaults to <repo>/.store-setup   (read-only: facts)
#   REPO_ROOT         defaults to `git rev-parse --show-toplevel`
#
# Exit codes: 0 ok, 1 validation, 2 refused (an id whose resolved values
# include a credential, under --format json), 64 usage.

set -uo pipefail

usage() { echo "FATAL: $*" >&2; exit 64; }
die() { echo "FATAL: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLE_REF="$SKILL_DIR/references/apple.md"
GOOGLE_REF="$SKILL_DIR/references/google.md"
HUAWEI_REF="$SKILL_DIR/references/huawei.md"

# The 27 console ids, exactly, in this order: the interface Task 2's
# state.sh and this skill's tests both depend on. Do not reorder or rename.
# The huawei-* ids are appended last because they are an optional extra
# store, added after the Apple and Google vocabulary was already an
# interface two suites diff positionally.
STEP_IDS=(
  apple-enrolment apple-agreements apple-bundle-id apple-app-record
  apple-asc-key apple-match-repo apple-testflight-groups
  apple-privacy-labels apple-pricing
  google-account google-app-record google-play-app-signing
  google-service-account google-play-grant google-tracks
  google-store-listing-fields google-content-rating google-data-safety
  google-target-audience google-app-access google-pricing
  huawei-account huawei-app-record huawei-api-client
  huawei-app-signing huawei-listing huawei-testers
)

# Ids whose resolved values may include a credential (a demo password, tax
# or banking details) and therefore refuse a machine-readable dump of them.
# huawei-api-client is here because its take-away *is* a credential: the
# AppGallery Connect client secret, shown exactly once and pasted straight
# into validate-huawei-credentials.sh.
CREDENTIAL_IDS=(google-app-access apple-agreements huawei-api-client)

is_valid_id() {
  local want="$1" id
  for id in "${STEP_IDS[@]}"; do [ "$id" = "$want" ] && return 0; done
  return 1
}

is_credential_id() {
  local want="$1" id
  for id in "${CREDENTIAL_IDS[@]}"; do [ "$id" = "$want" ] && return 0; done
  return 1
}

reference_file_for() {
  case "$1" in
    apple-*) printf '%s\n' "$APPLE_REF" ;;
    google-*) printf '%s\n' "$GOOGLE_REF" ;;
    huawei-*) printf '%s\n' "$HUAWEI_REF" ;;
    *) return 1 ;;
  esac
}

# --- CLI ---------------------------------------------------------------------

ID=""
FORMAT="text"
REPO=""
LIST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --format)
      [ $# -ge 2 ] || usage "--format needs an argument"
      FORMAT="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || usage "--repo needs owner/name"
      REPO="$2"
      shift 2
      ;;
    -*) usage "unknown option '$1'" ;;
    *)
      [ -z "$ID" ] || usage "unexpected extra argument '$1'"
      ID="$1"
      shift
      ;;
  esac
done

if [ "$LIST" -eq 1 ]; then
  printf '%s\n' "${STEP_IDS[@]}"
  exit 0
fi

[ -n "$ID" ] || usage "usage: console-step.sh <id> [--format text|json] [--repo owner/name] | --list"
case "$FORMAT" in
  text | json) : ;;
  *) usage "--format must be 'text' or 'json', got '$FORMAT'" ;;
esac
is_valid_id "$ID" || usage "unknown id '$ID' (see --list)"

if [ "$FORMAT" = "json" ] && is_credential_id "$ID"; then
  echo "FATAL: $ID: resolved values include a credential; refusing --format json (use --format text)" >&2
  exit 2
fi

REF_FILE="$(reference_file_for "$ID")" || die "no reference file for '$ID'"
[ -f "$REF_FILE" ] || die "reference file not found: $REF_FILE"

# --- extract the block ------------------------------------------------------

START_LINE="$(grep -n "^### \`${ID}\`" "$REF_FILE" | head -1 | cut -d: -f1)"
[ -n "$START_LINE" ] || die "no '### \`$ID\`' heading in $REF_FILE"
END_LINE="$(awk -v s="$START_LINE" 'NR>s && /^### `/{print NR-1; exit}' "$REF_FILE")"
[ -n "$END_LINE" ] || END_LINE="$(wc -l < "$REF_FILE" | tr -d ' ')"
BLOCK="$(sed -n "${START_LINE},${END_LINE}p" "$REF_FILE")"

field_get() {
  # field_get <field-name>
  printf '%s\n' "$BLOCK" | grep -m1 "^\*\*$1:\*\*" | sed -E "s/^\*\*$1:\*\*[[:space:]]*//"
}

# shellcheck disable=SC2016 # the pattern is a literal regex, not a shell expansion
TITLE="$(printf '%s\n' "$BLOCK" | head -1 | sed -E 's/^### `[a-z0-9-]+` — //')"
CONSOLE_LINE="$(field_get Console)"
CLICK_PATH="$(field_get Click-path)"
ENTER="$(field_get Enter)"
TAKE_AWAY="$(field_get "Take away")"
CONFIRM="$(field_get Confirm)"
BROWSER_MODE="$(field_get "Browser mode")"
GUIDED_MODE="$(field_get "Guided mode")"
THEN="$(field_get Then)"

for name in CONSOLE_LINE CLICK_PATH ENTER TAKE_AWAY CONFIRM BROWSER_MODE GUIDED_MODE THEN; do
  [ -n "${!name}" ] || die "$ID: missing '${name}' field in $REF_FILE"
done

SEP=" — "
CONSOLE_NAME="${CONSOLE_LINE%%"$SEP"*}"
CONSOLE_URL="${CONSOLE_LINE#*"$SEP"}"
CONFIRM_CLASS="${CONFIRM%% *}"

# --- resolve Enter:/Take away: values where a repo-local source exists -----

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "${STORE_SETUP_DIR:-}" ]; then
  if [ -n "$REPO_ROOT" ]; then
    STORE_SETUP_DIR="$REPO_ROOT/.store-setup"
  fi
fi
STATE_FILE="${STORE_SETUP_DIR:+$STORE_SETUP_DIR/state.json}"

REPO_ARGS=()
[ -z "$REPO" ] || REPO_ARGS=(--repo "$REPO")

gh_var_value() {
  # gh_var_value <VAR_NAME> - empty on any failure or if unset
  local name="$1" json
  json="$(gh variable list --json name,value "${REPO_ARGS[@]+"${REPO_ARGS[@]}"}" 2>/dev/null)" || return 0
  printf '%s' "$json" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
const name = process.argv[1];
const v = data.find((x) => x.name === name);
process.stdout.write(v ? v.value : "");
' "$name" 2>/dev/null
}

fact_value() {
  # fact_value <key> - empty when the state file or the key is missing
  local key="$1"
  [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || return 0
  node -e '
const fs = require("fs");
try {
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write((s.facts && s.facts[process.argv[2]]) || "");
} catch { process.stdout.write(""); }
' "$STATE_FILE" "$key" 2>/dev/null
}

pkg_name() {
  [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/package.json" ] || return 0
  node -e '
try {
  process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).name || "");
} catch { process.stdout.write(""); }
' "$REPO_ROOT/package.json" 2>/dev/null
}

metadata_value() {
  # metadata_value <platform> <filename>
  local f="$REPO_ROOT/${FASTLANE_DIRECTORY:-fastlane}/metadata/$1/en-US/$2"
  [ -n "$REPO_ROOT" ] && [ -f "$f" ] || return 0
  cat "$f"
}

RESOLVED_LABEL=""
RESOLVED_VALUE=""
WARNING=""

case "$ID" in
  apple-bundle-id)
    RESOLVED_LABEL="IOS_BUNDLE_ID (gh variable)"
    RESOLVED_VALUE="$(gh_var_value IOS_BUNDLE_ID)"
    case "$RESOLVED_VALUE" in
      com.example.*) WARNING="identifiers gate would reject this value" ;;
    esac
    ;;
  apple-app-record)
    RESOLVED_LABEL="app name (${FASTLANE_DIRECTORY:-fastlane}/metadata/ios/en-US/name.txt)"
    RESOLVED_VALUE="$(metadata_value ios name.txt)"
    ;;
  apple-asc-key)
    RESOLVED_LABEL="key name (package.json name)"
    RESOLVED_VALUE="$(pkg_name)"
    [ -z "$RESOLVED_VALUE" ] || RESOLVED_VALUE="${RESOLVED_VALUE}-ci"
    ;;
  apple-match-repo)
    RESOLVED_LABEL="repo name (package.json name)"
    RESOLVED_VALUE="$(pkg_name)"
    [ -z "$RESOLVED_VALUE" ] || RESOLVED_VALUE="${RESOLVED_VALUE}-certificates"
    ;;
  apple-testflight-groups)
    RESOLVED_LABEL="TESTFLIGHT_INTERNAL_GROUP/TESTFLIGHT_EXTERNAL_GROUP (gh variables)"
    tf_internal="$(gh_var_value TESTFLIGHT_INTERNAL_GROUP)"
    tf_external="$(gh_var_value TESTFLIGHT_EXTERNAL_GROUP)"
    if [ -z "$tf_internal" ] && [ -z "$tf_external" ]; then
      RESOLVED_VALUE=""
    else
      [ -n "$tf_internal" ] || tf_internal="<ask the human>"
      [ -n "$tf_external" ] || tf_external="<ask the human>"
      RESOLVED_VALUE="internal=$tf_internal, external=$tf_external"
    fi
    ;;
  google-app-record)
    RESOLVED_LABEL="app name (${FASTLANE_DIRECTORY:-fastlane}/metadata/android/en-US/title.txt)"
    RESOLVED_VALUE="$(metadata_value android title.txt)"
    ;;
  google-service-account)
    RESOLVED_LABEL="service account name (package.json name)"
    RESOLVED_VALUE="$(pkg_name)"
    [ -z "$RESOLVED_VALUE" ] || RESOLVED_VALUE="${RESOLVED_VALUE}-publisher"
    ;;
  google-play-grant)
    RESOLVED_LABEL="service account email (state fact)"
    RESOLVED_VALUE="$(fact_value play_service_account_email)"
    ;;
esac

if [ -n "$RESOLVED_LABEL" ] && [ -z "$RESOLVED_VALUE" ]; then
  RESOLVED_VALUE="<ask the human>"
fi

# --- print -------------------------------------------------------------------

if [ "$FORMAT" = "json" ]; then
  node -e '
const [id, title, console_, url, clickPath, enter, takeAway, confirm, confirmClass,
  browser, guided, then, resolvedLabel, resolvedValue, warning] = process.argv.slice(1);
process.stdout.write(JSON.stringify({
  id, title, console: console_, url, click_path: clickPath, enter, take_away: takeAway,
  confirm, confirm_class: confirmClass, browser_mode: browser, guided_mode: guided, then,
  resolved: resolvedLabel ? { label: resolvedLabel, value: resolvedValue } : null,
  warning: warning || null,
}, null, 2) + "\n");
' "$ID" "$TITLE" "$CONSOLE_NAME" "$CONSOLE_URL" "$CLICK_PATH" "$ENTER" "$TAKE_AWAY" \
    "$CONFIRM" "$CONFIRM_CLASS" "$BROWSER_MODE" "$GUIDED_MODE" "$THEN" \
    "$RESOLVED_LABEL" "$RESOLVED_VALUE" "$WARNING"
  exit 0
fi

echo "$ID — $TITLE"
echo "Console: $CONSOLE_NAME"
echo "URL: $CONSOLE_URL"
echo "Click-path: $CLICK_PATH"
echo "Enter: $ENTER"
echo "Take away: $TAKE_AWAY"
echo "Confirm: $CONFIRM"
echo "Browser mode: $BROWSER_MODE"
echo "Guided mode: $GUIDED_MODE"
echo "Then: $THEN"
if [ -n "$RESOLVED_LABEL" ]; then
  echo "Resolved: $RESOLVED_LABEL -> $RESOLVED_VALUE"
fi
if [ -n "$WARNING" ]; then
  echo "WARNING: $WARNING"
fi

exit 0
