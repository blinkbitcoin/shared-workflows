#!/bin/bash
# Validate a Google Play service account JSON key before it is uploaded:
# valid JSON, the right key type (not the OAuth-client download Play
# Console sometimes hands out instead), and the fields fastlane's
# supply/validate_play_store_json_key needs.
#
# Usage: validate-play-json.sh --file <path> [--check-access] [--yes]
#
#   --check-access  also run `bundle exec fastlane run
#                   validate_play_store_json_key` (network). Offline checks
#                   must pass first, and this needs a `--yes` (or an
#                   interactive y/N on stdin) since it is a network call.
#
# Exit codes: 0 all checks pass, 1 one or more checks failed, 2 refused
# (network check declined), 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

FILE=""
CHECK_ACCESS=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die_usage "--file needs a path"
      FILE="$2"
      shift 2
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

[ -n "$FILE" ] || die_usage "--file is required"
[ -f "$FILE" ] || die_usage "file not found: $FILE"

FAILURES=()
fail() { FAILURES+=("$1"); }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/validate-play-json.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

FIELDS_OUT="$WORKDIR/fields.json"
if ! node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
} catch (e) {
  process.stderr.write("invalid JSON: " + e.message + "\n");
  process.exit(1);
}
fs.writeFileSync(process.argv[2], JSON.stringify(data));
' "$FILE" "$FIELDS_OUT" 2>"$WORKDIR/parse.err"; then
  fail "not valid JSON: $(head -1 "$WORKDIR/parse.err")"
fi

if [ ${#FAILURES[@]} -eq 0 ]; then
  TYPE="$(node -e 'const d=require(process.argv[1]); process.stdout.write(typeof d.type==="string"?d.type:"")' "$FIELDS_OUT" 2>/dev/null)"
  HAS_INSTALLED="$(node -e 'const d=require(process.argv[1]); process.stdout.write(d.installed?"1":"0")' "$FIELDS_OUT" 2>/dev/null)"
  CLIENT_EMAIL="$(node -e 'const d=require(process.argv[1]); process.stdout.write(typeof d.client_email==="string"?d.client_email:"")' "$FIELDS_OUT" 2>/dev/null)"

  if [ "$HAS_INSTALLED" = "1" ]; then
    fail "that is an OAuth client, not a service account key - download the JSON key from the service account's Keys tab instead"
  elif [ -z "$TYPE" ]; then
    fail "missing 'type' field - not a service account key"
  elif [ "$TYPE" != "service_account" ]; then
    fail "type is '$TYPE', expected 'service_account'"
  fi

  if [ -z "$CLIENT_EMAIL" ]; then
    fail "missing 'client_email' field"
  fi

  PRIVATE_KEY_PEM="$WORKDIR/private_key.pem"
  (umask 077 && : >"$PRIVATE_KEY_PEM")
  node -e 'const d=require(process.argv[1]); process.stdout.write(typeof d.private_key==="string"?d.private_key:"")' "$FIELDS_OUT" 2>/dev/null >"$PRIVATE_KEY_PEM"
  if [ ! -s "$PRIVATE_KEY_PEM" ]; then
    fail "missing or empty 'private_key' field"
  elif ! openssl pkey -in "$PRIVATE_KEY_PEM" -noout 2>"$WORKDIR/pkey.err"; then
    fail "'private_key' does not parse as a private key: $(head -1 "$WORKDIR/pkey.err")"
  fi
  rm -f "$PRIVATE_KEY_PEM"
fi

if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "OK: $FILE looks like a Google Play service account key"
else
  for f in "${FAILURES[@]}"; do
    echo "FAIL: $f" >&2
  done
  exit 1
fi

if [ "$CHECK_ACCESS" -eq 1 ]; then
  if [ "$YES" -ne 1 ]; then
    printf 'This contacts Google Play to verify access - continue? [y/N] ' >&2
    read -r ANSWER || ANSWER=""
    case "$ANSWER" in
      y | Y | yes | YES) : ;;
      *)
        echo "FATAL: refused - --check-access needs --yes or a y/Y answer" >&2
        exit 2
        ;;
    esac
  fi
  command -v bundle >/dev/null 2>&1 || {
    echo "FATAL: bundle not on PATH - cannot run --check-access" >&2
    exit 1
  }
  bundle exec fastlane run validate_play_store_json_key "json_key:$FILE"
fi
