#!/bin/bash
# Validate an Android upload keystore before it is base64'd into a GitHub
# secret: the alias exists, the password(s) actually open it, the key is
# RSA >= 2048 bits, and the certificate is valid for at least 25 years (Play
# refuses an upload once the signing certificate has expired, and a keystore
# is meant to outlive the app).
#
# Usage: validate-keystore.sh --keystore <file> --alias <alias>
#
#   ANDROID_UPLOAD_KEYSTORE_PASSWORD   the store password (required)
#   ANDROID_UPLOAD_KEY_PASSWORD        the key password (required)
#
# On success prints ANDROID_UPLOAD_CERT_SHA256=<colon-separated fingerprint>.
#
# Exit codes: 0 all checks pass, 1 one or more checks failed, 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

KEYSTORE=""
ALIAS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --keystore)
      [ $# -ge 2 ] || die_usage "--keystore needs a file"
      KEYSTORE="$2"
      shift 2
      ;;
    --alias)
      [ $# -ge 2 ] || die_usage "--alias needs a value"
      ALIAS="$2"
      shift 2
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

[ -n "$KEYSTORE" ] || die_usage "--keystore is required"
[ -n "$ALIAS" ] || die_usage "--alias is required"
[ -f "$KEYSTORE" ] || die_usage "keystore not found: $KEYSTORE"
command -v keytool >/dev/null 2>&1 || die_usage "keytool not on PATH (needs a JDK)"
STOREPASS="${ANDROID_UPLOAD_KEYSTORE_PASSWORD:-}"
KEYPASS="${ANDROID_UPLOAD_KEY_PASSWORD:-}"
[ -n "$STOREPASS" ] || die_usage "ANDROID_UPLOAD_KEYSTORE_PASSWORD is not set"
[ -n "$KEYPASS" ] || die_usage "ANDROID_UPLOAD_KEY_PASSWORD is not set"

FAILURES=()
fail() { FAILURES+=("$1"); }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/validate-keystore.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

LIST_OUT="$WORKDIR/list.out"
if ! keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" -storepass:env ANDROID_UPLOAD_KEYSTORE_PASSWORD \
  >"$LIST_OUT" 2>&1; then
  if grep -qi 'does not exist' "$LIST_OUT"; then
    fail "alias '$ALIAS' does not exist in $KEYSTORE"
  elif grep -qi 'password was incorrect\|tampered' "$LIST_OUT"; then
    fail "ANDROID_UPLOAD_KEYSTORE_PASSWORD did not open $KEYSTORE"
  else
    fail "keytool -list -v failed: $(head -1 "$LIST_OUT")"
  fi
  echo "keytool -list -v failed - not printing ANDROID_UPLOAD_CERT_SHA256" >&2
  for f in "${FAILURES[@]}"; do echo "FAIL: $f" >&2; done
  exit 1
fi

BITS="$(sed -nE 's/.*Subject Public Key Algorithm: ([0-9]+)-bit ([A-Za-z]+) key.*/\1 \2/p' "$LIST_OUT" | head -1)"
KEY_BITS="${BITS%% *}"
KEY_ALGO="${BITS##* }"
if [ "$KEY_ALGO" != "RSA" ]; then
  fail "key algorithm is '$KEY_ALGO', expected RSA"
elif [ -z "$KEY_BITS" ] || [ "$KEY_BITS" -lt 2048 ]; then
  fail "RSA key is ${KEY_BITS:-unknown} bits, expected >= 2048"
fi

SHA256="$(sed -nE 's/^[[:space:]]*SHA256: (.*)$/\1/p' "$LIST_OUT" | head -1)"
[ -n "$SHA256" ] || fail "could not read a SHA256 fingerprint from keytool -list -v output"

# 25 years, in seconds (365 * 24 * 3600 * 25). openssl -checkend avoids
# parsing keytool's locale-dependent "Valid ... until:" date string.
TWENTY_FIVE_YEARS=788400000
CERT_PEM="$WORKDIR/cert.pem"
if keytool -exportcert -alias "$ALIAS" -keystore "$KEYSTORE" -storepass:env ANDROID_UPLOAD_KEYSTORE_PASSWORD -rfc \
  >"$CERT_PEM" 2>"$WORKDIR/export.err"; then
  if ! openssl x509 -in "$CERT_PEM" -noout -checkend "$TWENTY_FIVE_YEARS" >/dev/null 2>&1; then
    fail "certificate is valid for less than 25 years from now"
  fi
else
  fail "keytool -exportcert failed: $(head -1 "$WORKDIR/export.err")"
fi

CSR_OUT="$WORKDIR/csr.pem"
if ! keytool -certreq -alias "$ALIAS" -keystore "$KEYSTORE" -storepass:env ANDROID_UPLOAD_KEYSTORE_PASSWORD \
  -keypass:env ANDROID_UPLOAD_KEY_PASSWORD -file "$CSR_OUT" >"$WORKDIR/certreq.out" 2>&1; then
  fail "ANDROID_UPLOAD_KEY_PASSWORD did not open the private key for alias '$ALIAS'"
fi

if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "ANDROID_UPLOAD_CERT_SHA256=$SHA256"
  exit 0
fi

[ -z "$SHA256" ] || echo "ANDROID_UPLOAD_CERT_SHA256=$SHA256"
for f in "${FAILURES[@]}"; do
  echo "FAIL: $f" >&2
done
exit 1
