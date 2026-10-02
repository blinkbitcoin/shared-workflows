#!/bin/bash
# Generate a new Android upload keystore. Refuses to write anywhere git
# would track (an upload keystore committed to history is unrecoverable —
# Play ties an app forever to the signing certificate inside it) and never
# prints a password to any output stream, even to keytool's own argv.
#
# Usage:
#   new-upload-keystore.sh --out <path> --alias <alias> [--dname <dn>] \
#     [--validity <days>] [--force]
#
#   ANDROID_UPLOAD_KEYSTORE_PASSWORD / ANDROID_UPLOAD_KEY_PASSWORD, if set,
#   are used as-is; otherwise each is generated with `openssl rand -base64
#   24`. Either way each ends up in the process environment and is handed
#   to keytool via `-storepass:env` / `-keypass:env`, never on argv, and
#   is written to <out>.storepass / <out>.keypass (chmod 600) so the
#   env-file lines below can pick it up - never printed anywhere.
#
# On success prints, on stdout, exactly these push-to-github.sh env-file
# lines and nothing else:
#   secret ANDROID_UPLOAD_KEYSTORE_BASE64@file=<out>.b64
#   secret ANDROID_UPLOAD_KEYSTORE_PASSWORD@file=<out>.storepass
#   secret ANDROID_UPLOAD_KEY_PASSWORD@file=<out>.keypass
#   secret ANDROID_UPLOAD_KEY_ALIAS=<alias>
#   variable ANDROID_UPLOAD_CERT_SHA256=<sha256>
# so `new-upload-keystore.sh ... > creds.env && push-to-github.sh --apply
# --yes --from-env-file creds.env` works directly.
#
# Exit codes: 0 ok, 1 validation failed (bad --validity, or the generated
# keystore's SHA256 could not be read), 2 refused (--out or one of the
# files it writes alongside it is not covered by .gitignore, or --out
# already exists without --force), 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }
die_validation() { echo "FATAL: $*" >&2; exit 1; }
die_refused() { echo "FATAL: $*" >&2; exit 2; }

OUT=""
ALIAS=""
DNAME="CN=Android Upload Key, O=App, C=US"
VALIDITY=10950
MIN_VALIDITY=9125
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || die_usage "--out needs a path"
      OUT="$2"
      shift 2
      ;;
    --alias)
      [ $# -ge 2 ] || die_usage "--alias needs a value"
      ALIAS="$2"
      shift 2
      ;;
    --dname)
      [ $# -ge 2 ] || die_usage "--dname needs a value"
      DNAME="$2"
      shift 2
      ;;
    --validity)
      [ $# -ge 2 ] || die_usage "--validity needs a number of days"
      VALIDITY="$2"
      shift 2
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

[ -n "$OUT" ] || die_usage "--out is required"
[ -n "$ALIAS" ] || die_usage "--alias is required"
command -v keytool >/dev/null 2>&1 || die_usage "keytool not on PATH (needs a JDK)"
[[ "$VALIDITY" =~ ^[0-9]+$ ]] || die_usage "--validity must be an integer number of days"
[ "$VALIDITY" -ge "$MIN_VALIDITY" ] ||
  die_validation "--validity $VALIDITY is below the minimum of $MIN_VALIDITY days (25 years)"

# Absolute path, without requiring OUT (or its directory) to exist yet -
# the .gitignore check below must run before anything is created.
case "$OUT" in
  /*) : ;;
  *) OUT="$PWD/$OUT" ;;
esac
OUT_DIR="$(dirname "$OUT")"

ANCESTOR="$OUT_DIR"
while [ ! -d "$ANCESTOR" ]; do
  ANCESTOR="$(dirname "$ANCESTOR")"
done
REPO_ROOT_FOR_OUT="$(git -C "$ANCESTOR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT_FOR_OUT" ] || die_usage "--out ($OUT) is not inside a git repository"

STOREPASS_FILE="$OUT.storepass"
KEYPASS_FILE="$OUT.keypass"
BASE64_FILE="$OUT.b64"

for path in "$OUT" "$STOREPASS_FILE" "$KEYPASS_FILE" "$BASE64_FILE"; do
  git -C "$REPO_ROOT_FOR_OUT" check-ignore -q -- "$path" ||
    die_refused "$path is not covered by .gitignore - an upload keystore (and the files written alongside it) must never be committed"
done

[ ! -e "$OUT" ] || [ "$FORCE" -eq 1 ] ||
  die_refused "--out ($OUT) already exists - pass --force to overwrite"

mkdir -p "$OUT_DIR"

if [ -z "${ANDROID_UPLOAD_KEYSTORE_PASSWORD:-}" ]; then
  ANDROID_UPLOAD_KEYSTORE_PASSWORD="$(openssl rand -base64 24)"
fi
if [ -z "${ANDROID_UPLOAD_KEY_PASSWORD:-}" ]; then
  ANDROID_UPLOAD_KEY_PASSWORD="$(openssl rand -base64 24)"
fi
export ANDROID_UPLOAD_KEYSTORE_PASSWORD ANDROID_UPLOAD_KEY_PASSWORD

(umask 077 && printf '%s' "$ANDROID_UPLOAD_KEYSTORE_PASSWORD" >"$STOREPASS_FILE")
(umask 077 && printf '%s' "$ANDROID_UPLOAD_KEY_PASSWORD" >"$KEYPASS_FILE")

rm -f "$OUT"
# keytool's own output goes to a scratch directory, never next to the
# keystore: $OUT_DIR is a repo path, and a log there is one more file the
# .gitignore check above never cleared.
KEYTOOL_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/new-upload-keystore.XXXXXX")"
KEYTOOL_LOG="$KEYTOOL_LOG_DIR/keytool.log"
if ! keytool -genkeypair -keyalg RSA -keysize 2048 -storetype JKS \
  -keystore "$OUT" -alias "$ALIAS" \
  -storepass:env ANDROID_UPLOAD_KEYSTORE_PASSWORD -keypass:env ANDROID_UPLOAD_KEY_PASSWORD \
  -validity "$VALIDITY" -dname "$DNAME" >"$KEYTOOL_LOG" 2>&1; then
  echo "FATAL: keytool -genkeypair failed - see $KEYTOOL_LOG" >&2
  exit 1
fi
rm -rf "$KEYTOOL_LOG_DIR"

LIST_OUT="$(keytool -list -v -keystore "$OUT" -alias "$ALIAS" -storepass:env ANDROID_UPLOAD_KEYSTORE_PASSWORD 2>/dev/null)"
SHA256="$(printf '%s\n' "$LIST_OUT" | sed -nE 's/^[[:space:]]*SHA256: (.*)$/\1/p' | head -1)"
[ -n "$SHA256" ] || die_validation "could not read a SHA256 fingerprint from keytool -list -v output for $OUT"

(umask 077 && base64 -i "$OUT" >"$BASE64_FILE")

echo "secret ANDROID_UPLOAD_KEYSTORE_BASE64@file=$BASE64_FILE"
echo "secret ANDROID_UPLOAD_KEYSTORE_PASSWORD@file=$STOREPASS_FILE"
echo "secret ANDROID_UPLOAD_KEY_PASSWORD@file=$KEYPASS_FILE"
echo "secret ANDROID_UPLOAD_KEY_ALIAS=$ALIAS"
echo "variable ANDROID_UPLOAD_CERT_SHA256=$SHA256"
