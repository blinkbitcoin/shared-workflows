#!/bin/bash
# Push store credentials into GitHub as variables or secrets, never letting
# a value touch argv, a log line, or this script's own stdout — every value
# reaches `gh` on stdin, through `--body-file -`.
#
# Usage:
#   push-to-github.sh --plan [--from-env-file <f>] [--env internal|beta|production] [--repo owner/name]
#   push-to-github.sh --apply --yes [--from-env-file <f>] [--env internal|beta|production] [--repo owner/name]
#   push-to-github.sh --verify [--env internal|beta|production] [--repo owner/name]
#
# --from-env-file format: one entry per line, blank lines and lines
# starting with # ignored. Two forms:
#   <variable|secret> NAME=value
#   <variable|secret> NAME@file=<path>
# The @file form reads the whole file (read once, never echoed) as the
# value — the only way to carry a multi-line value such as
# PLAY_SERVICE_ACCOUNT_JSON or a PEM. Every non-comment line must contain
# either `=` or `@file=`; a line with neither, a duplicate NAME, an unknown
# NAME, or a NAME whose claimed class disagrees with the table below is
# refused. The leading word is the caller's *claimed* class; it is checked
# against this script's own class table, which is authoritative.
#
# Every path the caller hands over - the --from-env-file path itself and
# every `@file=` path inside it - must be `git check-ignore`d or outside any
# git repository, the same rule new-upload-keystore.sh applies to the files
# it writes; anything git could track is refused (exit 2) by name.
#
# Exit codes: 0 ok (an apply that set everything; a plan; a verify that
# found nothing missing for an enabled toggle), 1 an apply stopped after
# `gh` failed on some name (remaining names are left unset), a verify found
# something missing, or a `gh variable list`/`gh secret list` failed (set
# cannot be told from missing, so neither --plan nor --verify may guess),
# 2 refused (wrong class, or a credential path git could track), 3 an apply
# with an env file holding no entries, or a verify that found no toggle
# enabled - nothing to do, 64 usage (including --apply without --yes or
# without --from-env-file, an unknown or duplicate name, a malformed
# env-file line, and a missing --from-env-file or @file= path).

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }
die_refused() { echo "FATAL: $*" >&2; exit 2; }

# --- the class table ---------------------------------------------------------
# Authoritative: docs/release-runbook.md "## Variables and secrets". Tests
# in tests/run.sh assert this stays equal to that file's two tables and to
# every vars.*/secrets.* name .github/workflows reads.
VARIABLE_NAMES="IOS_BUNDLE_ID IOS_SCHEME ANDROID_PACKAGE XCODE_VERSION IOS_SIGNING_ENABLED ANDROID_SIGNING_ENABLED STORE_UPLOADS_ENABLED STORE_METADATA_SYNC_ENABLED HUAWEI_APP_ID HUAWEI_UPLOADS_ENABLED HUAWEI_SUBMIT_DELAY_SECONDS HUAWEI_FEEDBACK_EMAIL HUAWEI_TEST_DAYS IOS_METADATA_EDIT_LIVE PLAY_METADATA_TRACK BUILD_NUMBER_OFFSET WORKFLOWS_MACOS_RUNNER TESTFLIGHT_INTERNAL_GROUP TESTFLIGHT_EXTERNAL_GROUP PLAY_UPDATE_PRIORITY ANDROID_UPLOAD_CERT_SHA256 OTA_ENABLED EXPO_UPDATES_URL OTA_CLI_VERSION STORE_NOTES_INCLUDE_CHANGELOG STORE_NOTES_LLM_PROVIDER STORE_NOTES_LLM_MODEL STORE_NOTES_LLM_EFFORT STORE_NOTES_LLM_EXTRA_PARAMS OPENAI_BASE_URL SECURITY_ENABLED SECURITY_LLM_PROVIDER SECURITY_LLM_MODEL SECURITY_LLM_EFFORT SECURITY_LLM_EXTRA_PARAMS EXPO_PUBLIC_API_URL EXPO_PUBLIC_APP_NAME EXPO_PUBLIC_WEB_DOMAIN EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE E2E_IOS"
SECRET_NAMES="MATCH_PASSWORD MATCH_GIT_URL MATCH_GIT_BASIC_AUTHORIZATION ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64 ANDROID_UPLOAD_KEYSTORE_BASE64 ANDROID_UPLOAD_KEYSTORE_PASSWORD ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD PLAY_SERVICE_ACCOUNT_JSON HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET OTA_PUBLISH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY APP_REVIEW_EMAIL APP_REVIEW_FIRST_NAME APP_REVIEW_LAST_NAME APP_REVIEW_PHONE APP_REVIEW_DEMO_USER APP_REVIEW_DEMO_PASSWORD APP_REVIEW_NOTES"

# Toggle variables --verify checks, and the names each hard-requires once
# true. id|needs (needs is space-separated).
#
# HUAWEI_UPLOADS_ENABLED is deliberately NOT part of STORE_UPLOADS_ENABLED's
# set: AppGallery is an opt-in extra store, so a repository can have uploads
# on without ever holding a Huawei credential. Its own row below is what
# makes the pair and the app id required, once someone turns it on.
#
# STORE_UPLOADS_ENABLED's set is a superset of IOS_SIGNING_ENABLED's and
# ANDROID_SIGNING_ENABLED's: turning uploads on implies both platforms are
# signed (a store upload of an unsigned build makes no sense), plus
# TESTFLIGHT_EXTERNAL_GROUP, which `promote_beta` requires outright
# (fastlane/lanes/ios.rb, ~line 170).
TOGGLES_TABLE="
IOS_SIGNING_ENABLED|MATCH_PASSWORD MATCH_GIT_URL ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64
ANDROID_SIGNING_ENABLED|ANDROID_UPLOAD_KEYSTORE_BASE64 ANDROID_UPLOAD_KEYSTORE_PASSWORD ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD
STORE_UPLOADS_ENABLED|PLAY_SERVICE_ACCOUNT_JSON ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64 MATCH_PASSWORD MATCH_GIT_URL TESTFLIGHT_EXTERNAL_GROUP ANDROID_UPLOAD_KEYSTORE_BASE64 ANDROID_UPLOAD_KEYSTORE_PASSWORD ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD
STORE_METADATA_SYNC_ENABLED|PLAY_SERVICE_ACCOUNT_JSON ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64
OTA_ENABLED|OTA_PUBLISH_TOKEN OTA_CLI_VERSION EXPO_UPDATES_URL
HUAWEI_UPLOADS_ENABLED|HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET HUAWEI_APP_ID
"

# Soft requirements: missing is a WARN, not a failure (does not affect the
# exit code). id|name|reason.
WARN_TOGGLES_TABLE="
IOS_SIGNING_ENABLED|MATCH_GIT_BASIC_AUTHORIZATION|optional (an SSH match git url needs no basic-auth header)
ANDROID_SIGNING_ENABLED|ANDROID_UPLOAD_CERT_SHA256|unset - verify-android.sh's signature check degrades to 'skip'
"

class_of() {
  local name="$1" n
  for n in $VARIABLE_NAMES; do [ "$n" = "$name" ] && { echo "variable"; return 0; }; done
  for n in $SECRET_NAMES; do [ "$n" = "$name" ] && { echo "secret"; return 0; }; done
  echo ""
  return 1
}

# --- args --------------------------------------------------------------------
MODE=""
FROM_ENV_FILE=""
ENVIRONMENT=""
REPO=""
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      MODE="plan"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --verify)
      MODE="verify"
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    --from-env-file)
      [ $# -ge 2 ] || die_usage "--from-env-file needs a path"
      FROM_ENV_FILE="$2"
      shift 2
      ;;
    --env)
      [ $# -ge 2 ] || die_usage "--env needs a value"
      case "$2" in
        internal | beta | production) : ;;
        *) die_usage "--env must be internal, beta or production" ;;
      esac
      ENVIRONMENT="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || die_usage "--repo needs owner/name"
      REPO="$2"
      shift 2
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

[ -n "$MODE" ] || die_usage "one of --plan, --apply or --verify is required"
[ "$MODE" != "apply" ] || [ "$YES" -eq 1 ] || die_usage "--apply needs --yes"

GH_REPO_ARGS=()
[ -z "$REPO" ] || GH_REPO_ARGS=(--repo "$REPO")
GH_ENV_ARGS=()
[ -z "$ENVIRONMENT" ] || GH_ENV_ARGS=(--env "$ENVIRONMENT")

# --- read the env file, validating every name against the class table ------
# Populated in file order, parallel arrays (bash 3.2 has no assoc arrays):
# ENTRY_NAMES[i] / ENTRY_VALUE_FILES[i] (a file holding entry i's exact
# value bytes - needed because a NAME@file= entry can be multi-line).
ENTRY_NAMES=()
ENTRY_VALUE_FILES=()

# Refuse any credential-carrying path git could track: it must be covered by
# .gitignore, or sit outside a git repository altogether. Same rule as
# new-upload-keystore.sh's --out check, for the same reason - a credential
# committed to history is unrecoverable.
assert_untrackable() {
  local label="$1" path="$2" dir
  case "$path" in
    /*) : ;;
    *) path="$PWD/$path" ;;
  esac
  dir="$(dirname "$path")"
  while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$dir" check-ignore -q -- "$path" ||
    die_refused "$label ($path) is inside a git repository and not covered by .gitignore - keep credential files outside the repository (\$TMPDIR) or under an ignored path"
}

if [ -n "$FROM_ENV_FILE" ]; then
  [ -f "$FROM_ENV_FILE" ] || die_usage "--from-env-file not found: $FROM_ENV_FILE"
  assert_untrackable "--from-env-file" "$FROM_ENV_FILE"
  ENTRY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/push-to-github.values.XXXXXX")"
  trap 'rm -rf "$ENTRY_DIR"' EXIT INT TERM HUP
  LINE_NO=0
  ENTRY_INDEX=0
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    LINE_NO=$((LINE_NO + 1))
    case "$LINE" in
      '' | '#'*) continue ;;
    esac
    CLAIMED_CLASS="${LINE%% *}"
    REST="${LINE#* }"
    [ "$REST" != "$LINE" ] || die_usage "--from-env-file line $LINE_NO is malformed (want '<variable|secret> NAME=value' or '<variable|secret> NAME@file=<path>'): $LINE"
    case "$CLAIMED_CLASS" in
      variable | secret) : ;;
      *) die_usage "--from-env-file line $LINE_NO: unknown class '$CLAIMED_CLASS' (want 'variable' or 'secret')" ;;
    esac

    VALUE_FILE="$ENTRY_DIR/$ENTRY_INDEX"
    if [[ "$REST" =~ ^([A-Za-z0-9_]+)@file=(.+)$ ]]; then
      NAME="${BASH_REMATCH[1]}"
      SRC_FILE="${BASH_REMATCH[2]}"
      [ -f "$SRC_FILE" ] || die_usage "--from-env-file line $LINE_NO: @file path not found: $SRC_FILE"
      assert_untrackable "--from-env-file line $LINE_NO: @file path" "$SRC_FILE"
      cp "$SRC_FILE" "$VALUE_FILE"
    elif [[ "$REST" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
      NAME="${BASH_REMATCH[1]}"
      printf '%s' "${BASH_REMATCH[2]}" >"$VALUE_FILE"
    else
      die_usage "--from-env-file line $LINE_NO is malformed (want '<variable|secret> NAME=value' or '<variable|secret> NAME@file=<path>'): $LINE"
    fi

    ACTUAL_CLASS="$(class_of "$NAME")"
    [ -n "$ACTUAL_CLASS" ] || die_usage "--from-env-file line $LINE_NO: unknown name '$NAME'"
    [ "$ACTUAL_CLASS" = "$CLAIMED_CLASS" ] ||
      die_refused "--from-env-file line $LINE_NO: '$NAME' is a $ACTUAL_CLASS, not a $CLAIMED_CLASS"

    for existing in "${ENTRY_NAMES[@]+"${ENTRY_NAMES[@]}"}"; do
      [ "$existing" != "$NAME" ] || die_usage "--from-env-file line $LINE_NO: duplicate name '$NAME'"
    done

    ENTRY_NAMES+=("$NAME")
    ENTRY_VALUE_FILES+=("$VALUE_FILE")
    ENTRY_INDEX=$((ENTRY_INDEX + 1))
  done <"$FROM_ENV_FILE"
fi

value_file_for() {
  local name="$1" i
  for ((i = 0; i < ${#ENTRY_NAMES[@]}; i++)); do
    if [ "${ENTRY_NAMES[$i]}" = "$name" ]; then
      printf '%s\n' "${ENTRY_VALUE_FILES[$i]}"
      return 0
    fi
  done
  return 1
}

has_entry() {
  local want="$1" n
  for n in "${ENTRY_NAMES[@]+"${ENTRY_NAMES[@]}"}"; do [ "$n" = "$want" ] && return 0; done
  return 1
}

# --- remote name/value listings ---------------------------------------------
# `gh variable list`/`gh secret list --json name,value` return a JSON array
# of {name, value}. Secrets never carry a real value (gh masks it), but the
# shape is the same, so one parser covers both.
json_to_names() { node -e '
let s = "";
process.stdin.on("data", (c) => (s += c));
process.stdin.on("end", () => {
  let arr = [];
  try { arr = JSON.parse(s); } catch (e) { arr = []; }
  for (const row of arr) process.stdout.write(row.name + "\n");
});
'; }
json_value_of() { node -e '
let s = "";
process.stdin.on("data", (c) => (s += c));
process.stdin.on("end", () => {
  let arr = [];
  try { arr = JSON.parse(s); } catch (e) { arr = []; }
  const row = arr.find((r) => r.name === process.argv[1]);
  process.stdout.write(row && row.value !== undefined ? String(row.value) : "");
});
' "$1"; }

# A failing `gh … list` is fatal, never an empty list: with no listing, a
# name that is already set cannot be told from one that is missing, so
# --plan would report everything missing and --verify would claim there is
# nothing to verify. Both listings are fetched once here, in the top-level
# shell (a `gh` failure inside a command substitution could only exit its
# own subshell), and every later lookup reads these caches.
VARIABLES_JSON=""
SECRETS_JSON=""
REMOTE_VARIABLE_NAMES_CACHE=""
REMOTE_SECRET_NAMES_CACHE=""
load_remote_listings() {
  local out
  out="$(gh variable list "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --json name,value 2>/dev/null)" || {
    echo "FATAL: gh variable list failed - cannot tell set from missing" >&2
    exit 1
  }
  VARIABLES_JSON="$out"
  out="$(gh secret list "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" "${GH_ENV_ARGS[@]+"${GH_ENV_ARGS[@]}"}" --json name 2>/dev/null)" || {
    echo "FATAL: gh secret list failed - cannot tell set from missing" >&2
    exit 1
  }
  SECRETS_JSON="$out"
  REMOTE_VARIABLE_NAMES_CACHE="$(printf '%s' "$VARIABLES_JSON" | json_to_names)"$'\n'
  REMOTE_SECRET_NAMES_CACHE="$(printf '%s' "$SECRETS_JSON" | json_to_names)"$'\n'
}

remote_has() {
  local class="$1" name="$2"
  if [ "$class" = "variable" ]; then
    printf '%s' "$REMOTE_VARIABLE_NAMES_CACHE" | grep -qx "$name"
  else
    printf '%s' "$REMOTE_SECRET_NAMES_CACHE" | grep -qx "$name"
  fi
}

# --- --plan ------------------------------------------------------------------
if [ "$MODE" = "plan" ]; then
  load_remote_listings
  for name in $VARIABLE_NAMES $SECRET_NAMES; do
    class="$(class_of "$name")"
    if remote_has "$class" "$name"; then
      status="unchanged"
    elif has_entry "$name"; then
      status="set"
    else
      status="missing"
    fi
    echo "$name ($class): $status"
  done
  exit 0
fi

# --- --verify ----------------------------------------------------------------
# Exit 0: at least one toggle was on and nothing it hard-requires is
# missing. Exit 1: at least one toggle was on and something is missing.
# Exit 3: no toggle is on - nothing to verify.
if [ "$MODE" = "verify" ]; then
  ANY_ENABLED=0
  ANY_MISSING=0
  load_remote_listings

  while IFS='|' read -r toggle needs; do
    [ -n "$toggle" ] || continue
    ENABLED="$(printf '%s' "$VARIABLES_JSON" | json_value_of "$toggle")"
    [ "$ENABLED" = "true" ] || continue
    ANY_ENABLED=1
    for name in $needs; do
      class="$(class_of "$name")"
      if ! remote_has "$class" "$name"; then
        echo "missing: $name ($class), required because $toggle=true"
        ANY_MISSING=1
      fi
    done
  done <<<"$TOGGLES_TABLE"

  while IFS='|' read -r toggle name reason; do
    [ -n "$toggle" ] || continue
    ENABLED="$(printf '%s' "$VARIABLES_JSON" | json_value_of "$toggle")"
    [ "$ENABLED" = "true" ] || continue
    class="$(class_of "$name")"
    remote_has "$class" "$name" || echo "WARN: $name ($class) $reason"
  done <<<"$WARN_TOGGLES_TABLE"

  [ "$ANY_ENABLED" -eq 1 ] || exit 3
  [ "$ANY_MISSING" -eq 0 ] || exit 1
  exit 0
fi

# --- --apply -------------------------------------------------------------
[ -n "$FROM_ENV_FILE" ] || die_usage "--apply needs --from-env-file"
[ ${#ENTRY_NAMES[@]} -gt 0 ] || exit 3

for name in "${ENTRY_NAMES[@]}"; do
  class="$(class_of "$name")"
  VALUE_FILE="$(value_file_for "$name")"
  if [ "$class" = "variable" ]; then
    if ! gh variable set "$name" "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --body-file - <"$VALUE_FILE" >/dev/null; then
      echo "FATAL: gh variable set $name failed - stopping (remaining names are still unset)" >&2
      exit 1
    fi
  else
    if ! gh secret set "$name" "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" "${GH_ENV_ARGS[@]+"${GH_ENV_ARGS[@]}"}" --body-file - <"$VALUE_FILE" >/dev/null; then
      echo "FATAL: gh secret set $name failed - stopping (remaining names are still unset)" >&2
      exit 1
    fi
  fi
  echo "set: $name ($class)"
done
