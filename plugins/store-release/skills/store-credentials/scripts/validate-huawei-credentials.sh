#!/bin/bash
# Validate the Huawei AppGallery Connect API client pair before it is pushed
# to GitHub: the client id and client secret have the shape AppGallery
# actually issues, they are not placeholders, and the numeric app id is an
# app id rather than a package name pasted into the wrong field.
#
# Both values are read from the environment only — HUAWEI_CLIENT_ID and
# HUAWEI_CLIENT_SECRET — never from argv, where a process listing would show
# them. Nothing here echoes a value: failures report lengths and character
# classes, never the text.
#
# Usage:
#   HUAWEI_CLIENT_ID=... HUAWEI_CLIENT_SECRET=... \
#     validate-huawei-credentials.sh [--app-id <numeric>] [--check-access] [--yes]
#
#   --app-id        also check the numeric app id's shape, and, under
#                   --check-access, ask AppGallery for that app's name
#   --check-access  also exchange the pair for an access token against
#                   AppGallery Connect (network). Offline checks must pass
#                   first, and this needs a `--yes` (or an interactive y/N on
#                   stdin) since it is a network call. The request body is
#                   written by `node` into a `umask 077` temp file and handed
#                   to curl as `--data-binary @file`, so neither value
#                   reaches curl's argv either.
#
# The token call is the check the fastlane plugin swallows: its `get_token`
# returns nil on an authentication error and the upload action then only
# prints "Cannot retrieve token", so a wrong secret in CI is a green job that
# uploaded nothing. A 200 response carrying `ret.code != 0` counts as a
# failure here for exactly that reason.
#
# Exit codes: 0 all checks pass, 1 one or more checks failed, 2 refused
# (network check declined), 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

APP_ID=""
CHECK_ACCESS=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app-id)
      [ $# -ge 2 ] || die_usage "--app-id needs a value"
      APP_ID="$2"
      shift 2
      ;;
    --client-id | --client-secret)
      die_usage "$1 is not accepted - a credential must not reach argv; set HUAWEI_CLIENT_ID and HUAWEI_CLIENT_SECRET in the environment instead"
      ;;
    --check-access)
      CHECK_ACCESS=1
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

FAILURES=()
fail() { FAILURES+=("$1"); }

CLIENT_ID="${HUAWEI_CLIENT_ID:-}"
CLIENT_SECRET="${HUAWEI_CLIENT_SECRET:-}"

# Placeholders people paste while wiring things up. Matched case-insensitively
# and as whole values, never as substrings - a real secret may well contain
# the letters "dummy" somewhere in its 64 hexadecimal characters.
is_placeholder() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    '' | dummy | changeme | placeholder | todo | xxx | 'your-client-id' | 'your-client-secret' | '<client-id>' | '<client-secret>') return 0 ;;
  esac
  return 1
}

# Pattern-matched in the shell rather than piped to grep: grep is line-based,
# so an embedded newline - the exact thing a copy/paste out of a console adds
# - would land on its own line and match nothing. The same reason the digit
# and hexadecimal checks below only run once this one has passed.
has_whitespace() {
  case "$1" in
    *[[:space:]]*) return 0 ;;
  esac
  return 1
}

# --- the client id -----------------------------------------------------------
if [ -z "$CLIENT_ID" ]; then
  fail "HUAWEI_CLIENT_ID is not set in the environment - export it (never pass it as an argument)"
elif has_whitespace "$CLIENT_ID"; then
  fail "HUAWEI_CLIENT_ID contains whitespace (${#CLIENT_ID} characters) - a copy/paste picked up a newline or a space"
elif is_placeholder "$CLIENT_ID"; then
  fail "HUAWEI_CLIENT_ID is a placeholder value, not the client id from AppGallery Connect"
elif ! printf '%s' "$CLIENT_ID" | env LC_ALL=C grep -qE '^[0-9]+$'; then
  fail "HUAWEI_CLIENT_ID is not all digits (${#CLIENT_ID} characters) - AppGallery issues a numeric client id; check the two halves of the pair are not swapped"
elif [ "${#CLIENT_ID}" -lt 15 ]; then
  echo "WARN: HUAWEI_CLIENT_ID is only ${#CLIENT_ID} digits - the ones AppGallery issues are longer than that, so check it was pasted whole" >&2
fi

# --- the client secret -------------------------------------------------------
if [ -z "$CLIENT_SECRET" ]; then
  fail "HUAWEI_CLIENT_SECRET is not set in the environment - export it (never pass it as an argument)"
elif has_whitespace "$CLIENT_SECRET"; then
  fail "HUAWEI_CLIENT_SECRET contains whitespace (${#CLIENT_SECRET} characters) - a copy/paste picked up a newline or a space"
elif is_placeholder "$CLIENT_SECRET"; then
  fail "HUAWEI_CLIENT_SECRET is a placeholder value, not the client secret from AppGallery Connect"
elif ! printf '%s' "$CLIENT_SECRET" | env LC_ALL=C grep -qE '^[0-9a-fA-F]+$'; then
  fail "HUAWEI_CLIENT_SECRET is not hexadecimal (${#CLIENT_SECRET} characters) - AppGallery issues a hexadecimal secret; check the two halves of the pair are not swapped"
elif [ "${#CLIENT_SECRET}" -lt 32 ]; then
  fail "HUAWEI_CLIENT_SECRET is ${#CLIENT_SECRET} characters, under the 32 minimum - it was truncated, or only part of it was copied"
fi

if [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" = "$CLIENT_SECRET" ]; then
  fail "HUAWEI_CLIENT_ID and HUAWEI_CLIENT_SECRET are the same value - one of them was pasted twice"
fi

# --- the app id --------------------------------------------------------------
if [ -n "$APP_ID" ]; then
  if has_whitespace "$APP_ID"; then
    fail "--app-id contains whitespace"
  elif ! printf '%s' "$APP_ID" | env LC_ALL=C grep -qE '^[1-9][0-9]*$'; then
    fail "--app-id '$APP_ID' is not a numeric app id with no leading zero - HUAWEI_APP_ID is the number on the AppGallery Connect app information page, not the package name"
  fi
fi

if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "OK: the HUAWEI_CLIENT_ID/HUAWEI_CLIENT_SECRET pair has the shape AppGallery Connect issues (client id ${#CLIENT_ID} digits, client secret ${#CLIENT_SECRET} hexadecimal characters)"
  [ -z "$APP_ID" ] || echo "OK: --app-id $APP_ID is a numeric app id"
else
  for f in "${FAILURES[@]}"; do
    echo "FAIL: $f" >&2
  done
  exit 1
fi

[ "$CHECK_ACCESS" -eq 1 ] || exit 0

# --- --check-access (network) ------------------------------------------------
if [ "$YES" -ne 1 ]; then
  printf 'This contacts AppGallery Connect to exchange the pair for an access token - continue? [y/N] ' >&2
  read -r ANSWER || ANSWER=""
  case "$ANSWER" in
    y | Y | yes | YES) : ;;
    *)
      echo "FATAL: refused - --check-access needs --yes or a y/Y answer" >&2
      exit 2
      ;;
  esac
fi

command -v curl >/dev/null 2>&1 || {
  echo "FATAL: curl not on PATH - cannot run --check-access" >&2
  exit 1
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/validate-huawei-credentials.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM HUP

TOKEN_BODY="$WORKDIR/token-request.json"
(umask 077 && : >"$TOKEN_BODY")
# node reads both halves from its own environment and JSON-encodes them; the
# body never passes through this script's argv or stdout.
node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({
  grant_type: "client_credentials",
  client_id: process.env.HUAWEI_CLIENT_ID,
  client_secret: process.env.HUAWEI_CLIENT_SECRET,
}));
' "$TOKEN_BODY" || {
  echo "FATAL: could not build the token request body" >&2
  exit 1
}

TOKEN_RESPONSE="$WORKDIR/token-response.json"
(umask 077 && : >"$TOKEN_RESPONSE")
if ! curl -sS -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "@$TOKEN_BODY" \
  -o "$TOKEN_RESPONSE" \
  'https://connect-api.cloud.huawei.com/api/oauth2/v1/token' 2>"$WORKDIR/curl.err"; then
  echo "FAIL: could not reach AppGallery Connect - $(head -1 "$WORKDIR/curl.err")" >&2
  exit 1
fi

# A 200 with ret.code != 0 is the shape the plugin swallows: the body says
# no, the status line says yes. Treat it as a failure, and report the code
# and message (never a credential) so a revoked client can be told from a
# mistyped one.
TOKEN_VERDICT="$(node -e '
const fs = require("fs");
let body;
try {
  body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
} catch (e) {
  process.stdout.write("bad-json\tthe response was not JSON"); // never e.message: it quotes the unparsed body
  process.exit(0);
}
const ret = body.ret || {};
if (ret.code !== undefined && Number(ret.code) !== 0) {
  process.stdout.write("rejected\tret.code " + ret.code + ": " + (ret.msg || "no message"));
  process.exit(0);
}
if (typeof body.access_token === "string" && body.access_token.length > 0) {
  process.stdout.write("ok\t" + body.access_token.length);
  process.exit(0);
}
process.stdout.write("no-token\tthe response carried no access_token");
' "$TOKEN_RESPONSE")"

TOKEN_STATUS="${TOKEN_VERDICT%%$'\t'*}"
TOKEN_DETAIL="${TOKEN_VERDICT#*$'\t'}"

case "$TOKEN_STATUS" in
  ok)
    echo "OK: AppGallery Connect issued an access token ($TOKEN_DETAIL characters, not printed)"
    ;;
  rejected)
    echo "FAIL: AppGallery Connect refused the pair - $TOKEN_DETAIL (the client id/secret is wrong or the API client was deleted)" >&2
    exit 1
    ;;
  *)
    echo "FAIL: AppGallery Connect's token response was not usable - $TOKEN_DETAIL" >&2
    exit 1
    ;;
esac

[ -n "$APP_ID" ] || exit 0

# The token is a credential too: it reaches curl through a header file rather
# than an -H argument, for the same reason the pair never touches argv.
ACCESS_TOKEN_HEADERS="$WORKDIR/headers.txt"
(umask 077 && : >"$ACCESS_TOKEN_HEADERS")
node -e '
const fs = require("fs");
const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
fs.writeFileSync(process.argv[2],
  "Authorization: Bearer " + body.access_token + "\n" +
  "client_id: " + process.env.HUAWEI_CLIENT_ID + "\n");
' "$TOKEN_RESPONSE" "$ACCESS_TOKEN_HEADERS" || {
  echo "FATAL: could not build the app-info request headers" >&2
  exit 1
}

APP_INFO_RESPONSE="$WORKDIR/app-info.json"
(umask 077 && : >"$APP_INFO_RESPONSE")
if ! curl -sS -H "@$ACCESS_TOKEN_HEADERS" \
  -o "$APP_INFO_RESPONSE" \
  "https://connect-api.cloud.huawei.com/api/publish/v2/app-info?appId=$APP_ID" 2>"$WORKDIR/curl-app.err"; then
  echo "FAIL: could not reach AppGallery Connect for app $APP_ID - $(head -1 "$WORKDIR/curl-app.err")" >&2
  exit 1
fi

APP_VERDICT="$(node -e '
const fs = require("fs");
let body;
try {
  body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
} catch (e) {
  process.stdout.write("bad-json\tthe response was not JSON"); // never e.message: it quotes the unparsed body
  process.exit(0);
}
const ret = body.ret || {};
if (ret.code !== undefined && Number(ret.code) !== 0) {
  process.stdout.write("rejected\tret.code " + ret.code + ": " + (ret.msg || "no message"));
  process.exit(0);
}
const info = body.appInfo || {};
const name = info.appName || info.name;
if (typeof name === "string" && name.length > 0) {
  process.stdout.write("ok\t" + name);
  process.exit(0);
}
process.stdout.write("no-app\tthe response carried no app name");
' "$APP_INFO_RESPONSE")"

APP_STATUS="${APP_VERDICT%%$'\t'*}"
APP_DETAIL="${APP_VERDICT#*$'\t'}"

case "$APP_STATUS" in
  ok)
    echo "OK: app $APP_ID is \"$APP_DETAIL\" - confirm that is the right app before pushing the pair"
    ;;
  rejected)
    echo "FAIL: AppGallery Connect refused the app lookup - $APP_DETAIL (the app id may belong to another developer account, or the API client's roles do not reach it)" >&2
    exit 1
    ;;
  *)
    echo "FAIL: no app record came back for app id $APP_ID - $APP_DETAIL" >&2
    exit 1
    ;;
esac

exit 0
