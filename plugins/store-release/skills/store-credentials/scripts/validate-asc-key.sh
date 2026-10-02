#!/bin/bash
# Validate the shape of an App Store Connect API key before it is ever
# uploaded anywhere: the .p8 must be a PKCS#8 EC (prime256v1) private key,
# not the PKCS#1 RSA shape a careless re-export sometimes produces, and the
# key id / issuer id must look like what Apple actually issues.
#
# Usage:
#   validate-asc-key.sh (--p8 <file|-> | --base64 <file|->) --key-id <id> \
#     --issuer-id <uuid> [--quiet]
#
# Exactly one of --p8 (raw PEM) / --base64 (base64 of the PEM, newlines
# allowed and stripped before decoding) is required. Every check runs and
# every failure is listed, rather than stopping at the first one.
#
# Exit codes: 0 all checks pass, 1 one or more checks failed, 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

P8_FILE=""
B64_FILE=""
KEY_ID=""
ISSUER_ID=""
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --p8)
      [ $# -ge 2 ] || die_usage "--p8 needs a file (or -)"
      P8_FILE="$2"
      shift 2
      ;;
    --base64)
      [ $# -ge 2 ] || die_usage "--base64 needs a file (or -)"
      B64_FILE="$2"
      shift 2
      ;;
    --key-id)
      [ $# -ge 2 ] || die_usage "--key-id needs a value"
      KEY_ID="$2"
      shift 2
      ;;
    --issuer-id)
      [ $# -ge 2 ] || die_usage "--issuer-id needs a value"
      ISSUER_ID="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

[ -n "$P8_FILE" ] || [ -n "$B64_FILE" ] || die_usage "one of --p8 or --base64 is required"
[ -z "$P8_FILE" ] || [ -z "$B64_FILE" ] || die_usage "--p8 and --base64 are mutually exclusive"
[ -n "$KEY_ID" ] || die_usage "--key-id is required"
[ -n "$ISSUER_ID" ] || die_usage "--issuer-id is required"

FAILURES=()
fail() { FAILURES+=("$1"); }
note() { [ "$QUIET" -eq 1 ] || echo "ok: $1"; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/validate-asc-key.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
PEM_FILE="$WORKDIR/key.p8"
(umask 077 && : >"$PEM_FILE")

if [ -n "$P8_FILE" ]; then
  if [ "$P8_FILE" = "-" ]; then
    cat >"$PEM_FILE"
  else
    [ -f "$P8_FILE" ] || die_usage "--p8 file not found: $P8_FILE"
    cat "$P8_FILE" >"$PEM_FILE"
  fi
else
  RAW="$WORKDIR/raw.b64"
  (umask 077 && : >"$RAW")
  if [ "$B64_FILE" = "-" ]; then
    cat >"$RAW"
  else
    [ -f "$B64_FILE" ] || die_usage "--base64 file not found: $B64_FILE"
    cat "$B64_FILE" >"$RAW"
  fi
  # Strip newlines (and any surrounding whitespace) before decoding — a
  # base64 blob pasted from a GitHub secret editor commonly has them.
  tr -d '\n\r ' <"$RAW" >"$WORKDIR/raw.stripped.b64"
  if ! base64 -d <"$WORKDIR/raw.stripped.b64" >"$PEM_FILE" 2>"$WORKDIR/b64.err"; then
    fail "input could not be base64-decoded: $(head -1 "$WORKDIR/b64.err")"
  fi
fi

if [ ${#FAILURES[@]} -eq 0 ]; then
  if head -1 "$PEM_FILE" | grep -q '^-----BEGIN RSA PRIVATE KEY-----'; then
    fail "key is a PKCS#1 RSA private key (-----BEGIN RSA PRIVATE KEY-----); App Store Connect issues a PKCS#8 EC key (-----BEGIN PRIVATE KEY-----) - re-download the .p8 from Users and Access -> Integrations"
  elif ! head -1 "$PEM_FILE" | grep -q '^-----BEGIN PRIVATE KEY-----'; then
    fail "input does not look like a PEM private key (expected a -----BEGIN PRIVATE KEY----- header)"
  else
    note "PKCS#8 header present"
    if PKEY_TEXT="$(openssl pkey -in "$PEM_FILE" -noout -text 2>"$WORKDIR/pkey.err")"; then
      if printf '%s\n' "$PKEY_TEXT" | grep -q 'ASN1 OID: prime256v1'; then
        note "EC key on prime256v1 (P-256)"
      else
        fail "key is not an EC key on the prime256v1 (P-256) curve"
      fi
    else
      fail "openssl could not parse the key: $(head -1 "$WORKDIR/pkey.err")"
    fi
  fi
fi

if [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  note "key id '$KEY_ID' looks right"
else
  fail "--key-id '$KEY_ID' does not match the 10-character App Store Connect key id shape (^[A-Z0-9]{10}\$)"
fi

if [[ "$ISSUER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  note "issuer id '$ISSUER_ID' looks like a UUID"
else
  fail "--issuer-id '$ISSUER_ID' is not a UUID (Users and Access -> Integrations -> Issuer ID, one per team)"
fi

if [ ${#FAILURES[@]} -eq 0 ]; then
  [ "$QUIET" -eq 1 ] || echo "OK: App Store Connect API key looks right"
  exit 0
fi

for f in "${FAILURES[@]}"; do
  echo "FAIL: $f" >&2
done
exit 1
