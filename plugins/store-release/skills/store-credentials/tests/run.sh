#!/bin/bash
# Offline tests for the store-credentials skill: all seven scripts and
# SKILL.md. Real openssl throughout; real keytool if it is on PATH
# (generating an actual keystore under $WORK, and wrapped by a PATH shim
# that logs argv - never a password value - before exec'ing the real
# binary), otherwise a fake keytool serving canned `-list -v` output. `gh`
# is always a fake that records argv and stdin (never a real network call,
# never a real repository).
#
#   ./tests/run.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# Set to an app checkout to also compare the script's variable and secret names with
# that app's runbook table and the vars.* / secrets.* its workflows read. Without it
# those comparisons are skipped, by name: the lists are the template's, and only an
# app has the files to compare them with.
APP_REPO_ROOT="${APP_REPO_ROOT:-}"
FIXTURES_DIR="$TESTS_DIR/fixtures"

VALIDATE_ASC_KEY="$SKILL_DIR/scripts/validate-asc-key.sh"
VALIDATE_KEYSTORE="$SKILL_DIR/scripts/validate-keystore.sh"
VALIDATE_PLAY_JSON="$SKILL_DIR/scripts/validate-play-json.sh"
VALIDATE_MATCH_REPO="$SKILL_DIR/scripts/validate-match-repo.sh"
VALIDATE_HUAWEI="$SKILL_DIR/scripts/validate-huawei-credentials.sh"
NEW_UPLOAD_KEYSTORE="$SKILL_DIR/scripts/new-upload-keystore.sh"
PUSH_TO_GITHUB="$SKILL_DIR/scripts/push-to-github.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"
RUNBOOK="$APP_REPO_ROOT/docs/release-runbook.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/store-credentials-tests.XXXXXX")"
PASS=0
FAIL=0
SKIP=0
trap 'rm -rf "$WORK"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"
}
skip() {
  SKIP=$((SKIP + 1))
  printf '  \033[33mSKIP\033[0m %s\n' "$1"
}
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "expected output to contain '$2', got: $3"; fi
}
check_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1" "expected output NOT to contain '$2', got: $3"; else ok "$1"; fi
}

# --- fakes -------------------------------------------------------------------
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"

# `gh`: only `variable list` / `secret list` (served from $FAKE_GH_VARS /
# $FAKE_GH_SECRETS) and `variable set` / `secret set` (which log argv and
# stdin to $GH_LOG) are implemented. `list` is deliberately NOT logged: a
# --plan run should leave $GH_LOG empty.
cat >"$FAKEBIN/gh" <<'FAKE_GH'
#!/bin/bash
if [ "$1" = "variable" ] && [ "$2" = "list" ]; then
  cat "${FAKE_GH_VARS:?FAKE_GH_VARS not set}"
  exit 0
fi
if [ "$1" = "secret" ] && [ "$2" = "list" ]; then
  cat "${FAKE_GH_SECRETS:?FAKE_GH_SECRETS not set}"
  exit 0
fi
if { [ "$1" = "variable" ] || [ "$1" = "secret" ]; } && [ "$2" = "set" ]; then
  NAME="$3"
  STDIN_CONTENT="$(cat)"
  {
    printf 'ARGV: %s\n' "$*"
    printf 'STDIN(%s): %s\n' "$NAME" "$STDIN_CONTENT"
  } >>"${GH_LOG:?GH_LOG not set}"
  if [ -n "${FAKE_GH_FAIL_ON:-}" ] && [ "$NAME" = "$FAKE_GH_FAIL_ON" ]; then
    exit 1
  fi
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

echo "== validate-asc-key.sh"

P256_KEY="$WORK/asc_key.p8"
openssl ecparam -genkey -name prime256v1 2>/dev/null | openssl pkcs8 -topk8 -nocrypt >"$P256_KEY"
RSA_PKCS1_KEY="$WORK/rsa_pkcs1.pem"
# `genrsa` writes PKCS#1 on LibreSSL (macOS) and OpenSSL 1.1, but PKCS#8 on
# OpenSSL 3 (the Linux runners) unless asked for -traditional, which the other
# two do not know. On OpenSSL 3 without the flag this fixture was a PKCS#8 RSA
# key: still rejected, but for a different reason than the case below names.
openssl genrsa -traditional -out "$RSA_PKCS1_KEY" 2048 2>/dev/null ||
  openssl genrsa -out "$RSA_PKCS1_KEY" 2048 2>/dev/null
check "the RSA fixture really is PKCS#1" "-----BEGIN RSA PRIVATE KEY-----" "$(head -1 "$RSA_PKCS1_KEY")"

GOOD_KEY_ID="ABCD123456"
GOOD_ISSUER_ID="69a6de7d-c3a2-47e3-e053-5b8c7c11a4d1"

out=$("$VALIDATE_ASC_KEY" --p8 "$P256_KEY" --key-id "$GOOD_KEY_ID" --issuer-id "$GOOD_ISSUER_ID" 2>&1)
check "a real P-256 PKCS#8 key passes" "0" "$?"

out=$("$VALIDATE_ASC_KEY" --p8 "$RSA_PKCS1_KEY" --key-id "$GOOD_KEY_ID" --issuer-id "$GOOD_ISSUER_ID" 2>&1)
rc=$?
check "a PKCS#1 RSA key fails" "1" "$rc"
check_contains "the PKCS#1 failure names the RSA/PKCS#1 problem" "PKCS#1 RSA" "$out"

B64_WITH_NEWLINES="$WORK/asc_key_newlines.b64"
base64 -i "$P256_KEY" | fold -w 40 >"$B64_WITH_NEWLINES"
out=$("$VALIDATE_ASC_KEY" --base64 "$B64_WITH_NEWLINES" --key-id "$GOOD_KEY_ID" --issuer-id "$GOOD_ISSUER_ID" 2>&1)
check "base64 with embedded newlines passes after stripping" "0" "$?"

TRUNCATED_B64="$WORK/asc_key_truncated.b64"
base64 -i "$P256_KEY" | head -c 20 >"$TRUNCATED_B64"
"$VALIDATE_ASC_KEY" --base64 "$TRUNCATED_B64" --key-id "$GOOD_KEY_ID" --issuer-id "$GOOD_ISSUER_ID" >/dev/null 2>&1
check "truncated base64 fails" "1" "$?"

out=$("$VALIDATE_ASC_KEY" --p8 "$P256_KEY" --key-id "abc" --issuer-id "$GOOD_ISSUER_ID" 2>&1)
rc=$?
check "key id 'abc' fails" "1" "$rc"
check_contains "the key-id failure mentions --key-id" "key-id" "$out"

out=$("$VALIDATE_ASC_KEY" --p8 "$P256_KEY" --key-id "$GOOD_KEY_ID" --issuer-id "not-a-uuid" 2>&1)
rc=$?
check "a non-UUID issuer id fails" "1" "$rc"
check_contains "the issuer-id failure mentions --issuer-id" "issuer-id" "$out"

KEY_ID_MSG=$("$VALIDATE_ASC_KEY" --p8 "$P256_KEY" --key-id "abc" --issuer-id "$GOOD_ISSUER_ID" 2>&1)
ISSUER_MSG=$("$VALIDATE_ASC_KEY" --p8 "$P256_KEY" --key-id "$GOOD_KEY_ID" --issuer-id "not-a-uuid" 2>&1)
if [ "$KEY_ID_MSG" != "$ISSUER_MSG" ]; then ok "key-id and issuer-id failures have distinct messages"; else bad "key-id and issuer-id failures have distinct messages" "identical: $KEY_ID_MSG"; fi

echo
echo "== validate-play-json.sh"

out=$("$VALIDATE_PLAY_JSON" --file "$FIXTURES_DIR/play-service-account.json" 2>&1)
check "the service-account fixture passes" "0" "$?"

out=$("$VALIDATE_PLAY_JSON" --file "$FIXTURES_DIR/play-oauth-client.json" 2>&1)
rc=$?
check "the OAuth-client fixture fails" "1" "$rc"
check_contains "it says it is an OAuth client, not a service account key" "that is an OAuth client, not a service account key" "$out"

TYPE_USER_JSON="$WORK/type-user.json"
node -e '
const fs=require("fs");
const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
d.type="user";
fs.writeFileSync(process.argv[2], JSON.stringify(d));
' "$FIXTURES_DIR/play-service-account.json" "$TYPE_USER_JSON"
"$VALIDATE_PLAY_JSON" --file "$TYPE_USER_JSON" >/dev/null 2>&1
check "type: user fails" "1" "$?"

INVALID_JSON="$WORK/invalid.json"
printf '{not valid json' >"$INVALID_JSON"
"$VALIDATE_PLAY_JSON" --file "$INVALID_JSON" >/dev/null 2>&1
check "invalid JSON fails" "1" "$?"

MISSING_EMAIL_JSON="$WORK/missing-email.json"
node -e '
const fs=require("fs");
const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
delete d.client_email;
fs.writeFileSync(process.argv[2], JSON.stringify(d));
' "$FIXTURES_DIR/play-service-account.json" "$MISSING_EMAIL_JSON"
"$VALIDATE_PLAY_JSON" --file "$MISSING_EMAIL_JSON" >/dev/null 2>&1
check "missing client_email fails" "1" "$?"

MISSING_PRIVATE_KEY_JSON="$WORK/missing-private-key.json"
node -e '
const fs=require("fs");
const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
delete d.private_key;
fs.writeFileSync(process.argv[2], JSON.stringify(d));
' "$FIXTURES_DIR/play-service-account.json" "$MISSING_PRIVATE_KEY_JSON"
out=$("$VALIDATE_PLAY_JSON" --file "$MISSING_PRIVATE_KEY_JSON" 2>&1)
check "missing private_key fails" "1" "$?"
check_contains "missing private_key names the field" "missing or empty 'private_key'" "$out"

GARBAGE_PRIVATE_KEY_JSON="$WORK/garbage-private-key.json"
node -e '
const fs=require("fs");
const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
d.private_key="not a real key, just garbage text";
fs.writeFileSync(process.argv[2], JSON.stringify(d));
' "$FIXTURES_DIR/play-service-account.json" "$GARBAGE_PRIVATE_KEY_JSON"
out=$("$VALIDATE_PLAY_JSON" --file "$GARBAGE_PRIVATE_KEY_JSON" 2>&1)
check "garbage private_key fails" "1" "$?"
check_contains "garbage private_key names the parse problem" "does not parse as a private key" "$out"

echo "refused --check-access without --yes"
printf 'n\n' | "$VALIDATE_PLAY_JSON" --file "$FIXTURES_DIR/play-service-account.json" --check-access >/dev/null 2>&1
check "--check-access declined on stdin exits 2" "2" "$?"

echo
echo "== validate-keystore.sh / new-upload-keystore.sh (keytool)"

KEYSTORE_GOOD="$WORK/upload-good.keystore"
KEYSTORE_SHORT="$WORK/upload-short.keystore"
STOREPASS="StorePass123!"
KEYPASS="KeyPass123!"

HAVE_REAL_KEYTOOL=0
KEYTOOL_ARGV_LOG="$WORK/keytool-argv.log"
: >"$KEYTOOL_ARGV_LOG"
export KEYTOOL_ARGV_LOG

if command -v keytool >/dev/null 2>&1; then
  HAVE_REAL_KEYTOOL=1
  REAL_KEYTOOL_BIN="$(command -v keytool)"
  # A logging shim, first on PATH: records argv (never a password - both
  # scripts under test are required to pass passwords via -storepass:env /
  # -keypass:env, never on argv) then execs the real keytool.
  cat >"$FAKEBIN/keytool" <<SHIM
#!/bin/bash
{ printf 'ARGV:'; printf ' %q' "\$@"; printf '\n'; } >>"\${KEYTOOL_ARGV_LOG:-/dev/null}"
exec "$REAL_KEYTOOL_BIN" "\$@"
SHIM
  chmod +x "$FAKEBIN/keytool"

  keytool -genkeypair -keyalg RSA -keysize 2048 -storetype JKS \
    -keystore "$KEYSTORE_GOOD" -alias upload -storepass "$STOREPASS" -keypass "$KEYPASS" \
    -validity 10950 -dname "CN=Test Upload, O=Test, C=US" >/dev/null 2>&1
  keytool -genkeypair -keyalg RSA -keysize 2048 -storetype JKS \
    -keystore "$KEYSTORE_SHORT" -alias upload -storepass "$STOREPASS" -keypass "$KEYPASS" \
    -validity 365 -dname "CN=Test Upload, O=Test, C=US" >/dev/null 2>&1
fi

if [ "$HAVE_REAL_KEYTOOL" -eq 1 ]; then
  : >"$KEYTOOL_ARGV_LOG"
  out=$(ANDROID_UPLOAD_KEYSTORE_PASSWORD="$STOREPASS" ANDROID_UPLOAD_KEY_PASSWORD="$KEYPASS" \
    "$VALIDATE_KEYSTORE" --keystore "$KEYSTORE_GOOD" --alias upload 2>&1)
  rc=$?
  check "a good keystore passes" "0" "$rc"
  check_contains "it prints ANDROID_UPLOAD_CERT_SHA256=" "ANDROID_UPLOAD_CERT_SHA256=" "$out"
  check "validate-keystore.sh's keytool argv never carries the store password" "0" "$(grep -cF -- "$STOREPASS" "$KEYTOOL_ARGV_LOG")"
  check "validate-keystore.sh's keytool argv never carries the key password" "0" "$(grep -cF -- "$KEYPASS" "$KEYTOOL_ARGV_LOG")"

  out=$(ANDROID_UPLOAD_KEYSTORE_PASSWORD="$STOREPASS" ANDROID_UPLOAD_KEY_PASSWORD="$KEYPASS" \
    "$VALIDATE_KEYSTORE" --keystore "$KEYSTORE_GOOD" --alias nope 2>&1)
  rc=$?
  check "a wrong alias fails" "1" "$rc"
  check_contains "wrong alias failure names the alias" "nope" "$out"

  out=$(ANDROID_UPLOAD_KEYSTORE_PASSWORD="wrong-password-entirely" ANDROID_UPLOAD_KEY_PASSWORD="$KEYPASS" \
    "$VALIDATE_KEYSTORE" --keystore "$KEYSTORE_GOOD" --alias upload 2>&1)
  rc=$?
  check "a wrong store password fails" "1" "$rc"

  out=$(ANDROID_UPLOAD_KEYSTORE_PASSWORD="$STOREPASS" ANDROID_UPLOAD_KEY_PASSWORD="$KEYPASS" \
    "$VALIDATE_KEYSTORE" --keystore "$KEYSTORE_SHORT" --alias upload 2>&1)
  rc=$?
  check "365-day validity fails" "1" "$rc"
  check_contains "365-day validity failure mentions 25 years" "25 years" "$out"
else
  echo "  (keytool not on PATH - installing a fake for canned output)"
  cat >"$FAKEBIN/keytool" <<'FAKE_KEYTOOL'
#!/bin/bash
KEYSTORE=""
ALIAS=""
STOREPASS=""
prev=""
for a in "$@"; do
  case "$prev" in
    -keystore) KEYSTORE="$a" ;;
    -alias) ALIAS="$a" ;;
    -storepass) STOREPASS="$a" ;;
  esac
  prev="$a"
done
if [ "$1" = "-list" ]; then
  if [ "$STOREPASS" != "StorePass123!" ]; then
    echo "keytool error: java.io.IOException: Keystore was tampered with, or password was incorrect" >&2
    exit 1
  fi
  if [ "$ALIAS" != "upload" ]; then
    echo "keytool error: java.lang.Exception: Alias <$ALIAS> does not exist" >&2
    exit 1
  fi
  echo "Alias name: upload"
  echo "Subject Public Key Algorithm: 2048-bit RSA key"
  echo "	 SHA256: AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
  exit 0
fi
if [ "$1" = "-exportcert" ]; then
  exit 3
fi
exit 1
FAKE_KEYTOOL
  chmod +x "$FAKEBIN/keytool"
  echo "  (fake keytool wired; good/wrong-alias/wrong-password covered, validity/export skipped)"
fi

echo
echo "== validate-match-repo.sh"

BARE_REPO="$WORK/match.git"
git init --bare -q "$BARE_REPO"
SEED_CLONE="$WORK/match-seed"
git init -q "$SEED_CLONE"
git -C "$SEED_CLONE" config user.email t@example.com
git -C "$SEED_CLONE" config user.name t
echo seed >"$SEED_CLONE/seed.txt"
git -C "$SEED_CLONE" add seed.txt
git -C "$SEED_CLONE" commit -qm seed
git -C "$SEED_CLONE" remote add origin "$BARE_REPO"
git -C "$SEED_CLONE" push -q origin HEAD:refs/heads/main

MATCH_APP_REPO="$WORK/match-app-repo"
mkdir -p "$MATCH_APP_REPO"
git init -q "$MATCH_APP_REPO"
git -C "$MATCH_APP_REPO" config user.email t@example.com
git -C "$MATCH_APP_REPO" config user.name t
printf 'certs/\n' >"$MATCH_APP_REPO/.gitignore"
git -C "$MATCH_APP_REPO" add .gitignore
git -C "$MATCH_APP_REPO" commit -qm init

out=$(REPO_ROOT="$MATCH_APP_REPO" STORE_SETUP_DIR="$WORK/no-state-match" "$VALIDATE_MATCH_REPO" --git-url "$BARE_REPO" 2>&1)
check "a reachable local bare repo passes" "0" "$?"

out=$(REPO_ROOT="$MATCH_APP_REPO" STORE_SETUP_DIR="$WORK/no-state-match" "$VALIDATE_MATCH_REPO" --git-url "$WORK/does-not-exist.git" 2>&1)
check "a missing repo fails" "1" "$?"

STATE_WITH_PROD="$WORK/state-with-prod"
mkdir -p "$STATE_WITH_PROD"
cat >"$STATE_WITH_PROD/state.json" <<EOF
{"schema":1,"mode":null,"steps":{},"facts":{"production_match_git_url":"$BARE_REPO"}}
EOF
out=$(REPO_ROOT="$MATCH_APP_REPO" STORE_SETUP_DIR="$STATE_WITH_PROD" "$VALIDATE_MATCH_REPO" --git-url "$BARE_REPO" 2>&1)
rc=$?
check "the production url from state is refused" "2" "$rc"

mkdir -p "$MATCH_APP_REPO/certs"
out=$(REPO_ROOT="$MATCH_APP_REPO" STORE_SETUP_DIR="$WORK/no-state-match" "$VALIDATE_MATCH_REPO" --git-url "$BARE_REPO" 2>&1)
check_contains "an existing certs/ dir triggers a warning" "WARN" "$out"
rm -rf "$MATCH_APP_REPO/certs"

# I7: the basic-auth header comes from MATCH_GIT_BASIC_AUTHORIZATION and
# reaches git through GIT_CONFIG_*, never through argv (a `git -c
# http.extraHeader=...` would show the credential in every process listing).
out=$(REPO_ROOT="$MATCH_APP_REPO" STORE_SETUP_DIR="$WORK/no-state-match" \
  "$VALIDATE_MATCH_REPO" --git-url "$BARE_REPO" --basic-auth "dXNlcjp0b2tlbg==" 2>&1)
rc=$?
check "--basic-auth is a usage error" "64" "$rc"
check_contains "...naming the environment variable instead" "MATCH_GIT_BASIC_AUTHORIZATION" "$out"

GITFAKE_DIR="$WORK/gitfake"
mkdir -p "$GITFAKE_DIR"
GIT_FAKE_ARGV_LOG="$WORK/git-argv.log"
GIT_FAKE_ENV_LOG="$WORK/git-env.log"
cat >"$GITFAKE_DIR/git" <<'FAKE_GIT'
#!/bin/bash
{ printf 'ARGV:'; printf ' %s' "$@"; printf '\n'; } >>"${GIT_FAKE_ARGV_LOG:?}"
env >>"${GIT_FAKE_ENV_LOG:?}"
exit 0
FAKE_GIT
chmod +x "$GITFAKE_DIR/git"

BASIC_AUTH_VALUE="dXNlcjpuZXZlci1pbi1hcmd2"
: >"$GIT_FAKE_ARGV_LOG"
: >"$GIT_FAKE_ENV_LOG"
out=$(PATH="$GITFAKE_DIR:$PATH" GIT_FAKE_ARGV_LOG="$GIT_FAKE_ARGV_LOG" GIT_FAKE_ENV_LOG="$GIT_FAKE_ENV_LOG" \
  MATCH_GIT_BASIC_AUTHORIZATION="$BASIC_AUTH_VALUE" \
  REPO_ROOT="$MATCH_APP_REPO" STORE_SETUP_DIR="$WORK/no-state-match" \
  "$VALIDATE_MATCH_REPO" --git-url "https://example.invalid/match.git" 2>&1)
check "a reachable url with MATCH_GIT_BASIC_AUTHORIZATION set exits 0" "0" "$?"
check "the basic-auth value never appears in git's argv" "0" "$(grep -cF "$BASIC_AUTH_VALUE" "$GIT_FAKE_ARGV_LOG")"
check "the basic-auth value reaches git through its environment" "yes" \
  "$(grep -qF "GIT_CONFIG_VALUE_0=Authorization: Basic $BASIC_AUTH_VALUE" "$GIT_FAKE_ENV_LOG" && echo yes || echo no)"
check "git is called with ls-remote --exit-code" "yes" \
  "$(grep -qF 'ARGV: ls-remote --exit-code' "$GIT_FAKE_ARGV_LOG" && echo yes || echo no)"

echo
echo "== validate-huawei-credentials.sh"

# A curl that fails the suite if it is ever reached: every case below is
# offline, and the --check-access case must refuse before any network call.
CURLFAKE_DIR="$WORK/curlfake"
mkdir -p "$CURLFAKE_DIR"
CURL_CALLED_MARKER="$WORK/curl-was-called"
cat >"$CURLFAKE_DIR/curl" <<'FAKE_CURL'
#!/bin/bash
printf 'called with: %s\n' "$*" >>"${CURL_CALLED_MARKER:?CURL_CALLED_MARKER not set}"
exit 0
FAKE_CURL
chmod +x "$CURLFAKE_DIR/curl"

GOOD_HUAWEI_CLIENT_ID="123456789012345678"
GOOD_HUAWEI_CLIENT_SECRET="0123456789abcdef0123456789abcdef0123456789abcdef"

out=$(HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" HUAWEI_CLIENT_SECRET="$GOOD_HUAWEI_CLIENT_SECRET" \
  "$VALIDATE_HUAWEI" --app-id 987654321 2>&1)
rc=$?
check "a well-formed pair with a numeric app id exits 0" "0" "$rc"
check_not_contains "...and never echoes the client id" "$GOOD_HUAWEI_CLIENT_ID" "$out"
check_not_contains "...and never echoes the client secret" "$GOOD_HUAWEI_CLIENT_SECRET" "$out"

out=$(HUAWEI_CLIENT_SECRET="$GOOD_HUAWEI_CLIENT_SECRET" "$VALIDATE_HUAWEI" 2>&1)
rc=$?
check "a missing HUAWEI_CLIENT_ID exits 1" "1" "$rc"
check_contains "...naming the environment variable" "HUAWEI_CLIENT_ID" "$out"

out=$(HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" "$VALIDATE_HUAWEI" 2>&1)
check "a missing HUAWEI_CLIENT_SECRET exits 1" "1" "$?"

out=$(HUAWEI_CLIENT_ID="not-a-number" HUAWEI_CLIENT_SECRET="$GOOD_HUAWEI_CLIENT_SECRET" \
  "$VALIDATE_HUAWEI" 2>&1)
rc=$?
check "a non-numeric client id exits 1" "1" "$rc"
check_contains "...saying it is not all digits" "not all digits" "$out"

out=$(HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" \
  HUAWEI_CLIENT_SECRET="$(printf '0123456789abcdef0123456789abcdef\n0123456789abcdef')" \
  "$VALIDATE_HUAWEI" 2>&1)
rc=$?
check "a secret with an embedded newline exits 1" "1" "$rc"
check_contains "...saying it carries whitespace" "contains whitespace" "$out"

out=$(HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" HUAWEI_CLIENT_SECRET="0123456789abcdef" \
  "$VALIDATE_HUAWEI" 2>&1)
check "a secret under 32 characters exits 1" "1" "$?"

out=$(HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" HUAWEI_CLIENT_SECRET="$GOOD_HUAWEI_CLIENT_ID" \
  "$VALIDATE_HUAWEI" 2>&1)
check "the same value pasted into both halves exits 1" "1" "$?"

out=$(HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" HUAWEI_CLIENT_SECRET="$GOOD_HUAWEI_CLIENT_SECRET" \
  "$VALIDATE_HUAWEI" --app-id com.acme.app 2>&1)
rc=$?
check "a package name pasted as the app id exits 1" "1" "$rc"
check_contains "...saying it is not a numeric app id" "not a numeric app id" "$out"

out=$(HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" HUAWEI_CLIENT_SECRET="$GOOD_HUAWEI_CLIENT_SECRET" \
  "$VALIDATE_HUAWEI" --client-secret "$GOOD_HUAWEI_CLIENT_SECRET" 2>&1)
rc=$?
check "--client-secret is a usage error" "64" "$rc"
check_contains "...naming the environment variables instead" "HUAWEI_CLIENT_SECRET" "$out"

: >"$CURL_CALLED_MARKER"
out=$(PATH="$CURLFAKE_DIR:$PATH" CURL_CALLED_MARKER="$CURL_CALLED_MARKER" \
  HUAWEI_CLIENT_ID="$GOOD_HUAWEI_CLIENT_ID" HUAWEI_CLIENT_SECRET="$GOOD_HUAWEI_CLIENT_SECRET" \
  "$VALIDATE_HUAWEI" --check-access </dev/null 2>&1)
rc=$?
check "--check-access declined on a closed stdin exits 2" "2" "$rc"
check "...and made no network call at all" "0" "$(wc -c <"$CURL_CALLED_MARKER" | tr -d ' ')"

echo
echo "== new-upload-keystore.sh"

KEYSTORE_APP_REPO="$WORK/keystore-app-repo"
mkdir -p "$KEYSTORE_APP_REPO/certs" "$KEYSTORE_APP_REPO/notignored"
git init -q "$KEYSTORE_APP_REPO"
git -C "$KEYSTORE_APP_REPO" config user.email t@example.com
git -C "$KEYSTORE_APP_REPO" config user.name t
printf 'certs/\n' >"$KEYSTORE_APP_REPO/.gitignore"
git -C "$KEYSTORE_APP_REPO" add .gitignore
git -C "$KEYSTORE_APP_REPO" commit -qm init

NEW_UPLOAD_ENV_FILE="$WORK/new-upload-keystore-stdout.env"

if [ "$HAVE_REAL_KEYTOOL" -eq 1 ]; then
  "$NEW_UPLOAD_KEYSTORE" --out "$KEYSTORE_APP_REPO/notignored/upload.keystore" --alias upload >/dev/null 2>&1
  check "a non-gitignored --out is refused" "2" "$?"

  : >"$KEYTOOL_ARGV_LOG"
  out=$("$NEW_UPLOAD_KEYSTORE" --out "$KEYSTORE_APP_REPO/certs/upload.keystore" --alias upload 2>/dev/null)
  rc=$?
  check "a fresh gitignored --out succeeds" "0" "$rc"
  printf '%s\n' "$out" >"$NEW_UPLOAD_ENV_FILE"
  check "it prints exactly five env-file lines" "5" "$(printf '%s\n' "$out" | grep -cE '^(variable|secret) ')"
  check_contains "it prints the ANDROID_UPLOAD_KEYSTORE_BASE64 @file line" "secret ANDROID_UPLOAD_KEYSTORE_BASE64@file=" "$out"
  check_contains "it prints the ANDROID_UPLOAD_KEYSTORE_PASSWORD @file line" "secret ANDROID_UPLOAD_KEYSTORE_PASSWORD@file=" "$out"
  check_contains "it prints the ANDROID_UPLOAD_KEY_PASSWORD @file line" "secret ANDROID_UPLOAD_KEY_PASSWORD@file=" "$out"
  check_contains "it prints secret ANDROID_UPLOAD_KEY_ALIAS=upload" "secret ANDROID_UPLOAD_KEY_ALIAS=upload" "$out"
  check_contains "it prints variable ANDROID_UPLOAD_CERT_SHA256=" "variable ANDROID_UPLOAD_CERT_SHA256=" "$out"

  check "new-upload-keystore.sh's keytool argv never carries a password value" "0" \
    "$(grep -cF -- "$(cat "$KEYSTORE_APP_REPO/certs/upload.keystore.storepass")" "$KEYTOOL_ARGV_LOG")"

  GEN_STOREPASS="$(cat "$KEYSTORE_APP_REPO/certs/upload.keystore.storepass" 2>/dev/null)"
  check_not_contains "the generated store password never appears in combined stdout+stderr" "$GEN_STOREPASS" "$out"

  "$NEW_UPLOAD_KEYSTORE" --out "$KEYSTORE_APP_REPO/certs/upload.keystore" --alias upload >/dev/null 2>&1
  check "an existing file without --force is refused" "2" "$?"

  "$NEW_UPLOAD_KEYSTORE" --out "$KEYSTORE_APP_REPO/certs/upload3.keystore" --alias upload3 --validity 100 >/dev/null 2>&1
  check "--validity 100 fails validation" "1" "$?"

  # I4: check-ignore every path it will write, not just --out.
  PARTIAL_GITIGNORE_REPO="$WORK/partial-gitignore-repo"
  mkdir -p "$PARTIAL_GITIGNORE_REPO/certs"
  git init -q "$PARTIAL_GITIGNORE_REPO"
  git -C "$PARTIAL_GITIGNORE_REPO" config user.email t@example.com
  git -C "$PARTIAL_GITIGNORE_REPO" config user.name t
  printf '*.keystore\n' >"$PARTIAL_GITIGNORE_REPO/.gitignore"
  git -C "$PARTIAL_GITIGNORE_REPO" add .gitignore
  git -C "$PARTIAL_GITIGNORE_REPO" commit -qm init
  out=$("$NEW_UPLOAD_KEYSTORE" --out "$PARTIAL_GITIGNORE_REPO/certs/upload.keystore" --alias upload 2>&1)
  rc=$?
  check "a .gitignore covering only *.keystore is refused" "2" "$rc"
  check_contains "the refusal names the uncovered .storepass file" ".storepass" "$out"
  check "nothing was written under a partially-ignored dir" "" "$(ls "$PARTIAL_GITIGNORE_REPO/certs" 2>/dev/null)"
else
  echo "  (keytool not on PATH - skipping new-upload-keystore.sh's keytool-dependent cases)"
fi

echo
echo "== push-to-github.sh"

GH_LOG="$WORK/gh.log"
: >"$GH_LOG"

VARS_EMPTY="$WORK/vars-empty.json"
echo '[]' >"$VARS_EMPTY"
SECRETS_EMPTY="$WORK/secrets-empty.json"
echo '[]' >"$SECRETS_EMPTY"

: >"$GH_LOG"
out=$(FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" "$PUSH_TO_GITHUB" --plan 2>&1)
rc=$?
check "--plan exits 0" "0" "$rc"
check "--plan writes nothing to gh.log" "0" "$(wc -c <"$GH_LOG" | tr -d ' ')"
check_contains "--plan reports missing names" "missing" "$out"
check_not_contains "--plan never prints a value-looking secret" "-----BEGIN" "$out"

ENV_FILE="$WORK/creds.env"
cat >"$ENV_FILE" <<EOF
variable IOS_BUNDLE_ID=com.example.app
secret ASC_KEY_ID=$GOOD_KEY_ID
EOF

: >"$GH_LOG"
"$PUSH_TO_GITHUB" --apply --from-env-file "$ENV_FILE" >/dev/null 2>&1
check "--apply without --yes exits 64" "64" "$?"
check "no --yes writes nothing to gh.log either" "0" "$(wc -c <"$GH_LOG" | tr -d ' ')"

WRONG_CLASS_FILE="$WORK/wrong-class.env"
echo "variable ASC_KEY_ID=$GOOD_KEY_ID" >"$WRONG_CLASS_FILE"
FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --plan --from-env-file "$WRONG_CLASS_FILE" >/dev/null 2>&1
check "a secret name given as a variable is refused" "2" "$?"

UNKNOWN_NAME_FILE="$WORK/unknown-name.env"
echo "variable NOT_A_REAL_NAME=x" >"$UNKNOWN_NAME_FILE"
FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --plan --from-env-file "$UNKNOWN_NAME_FILE" >/dev/null 2>&1
check "an unknown name exits 64" "64" "$?"

MALFORMED_LINE_FILE="$WORK/malformed-line.env"
echo "variable NAME_WITH_NO_EQUALS_OR_AT_FILE" >"$MALFORMED_LINE_FILE"
FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --plan --from-env-file "$MALFORMED_LINE_FILE" >/dev/null 2>&1
check "a line with neither = nor @file= exits 64" "64" "$?"

DUPLICATE_NAME_FILE="$WORK/duplicate-name.env"
cat >"$DUPLICATE_NAME_FILE" <<EOF
variable IOS_BUNDLE_ID=com.example.app
variable IOS_BUNDLE_ID=com.example.other
EOF
FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --plan --from-env-file "$DUPLICATE_NAME_FILE" >/dev/null 2>&1
check "a duplicate name exits 64" "64" "$?"

# C2/I7: the @file form carries a multi-line value intact.
MULTILINE_JSON_FILE="$WORK/multiline.json"
printf '{\n  "a": 1,\n  "b": 2\n}\n' >"$MULTILINE_JSON_FILE"
AT_FILE_ENV="$WORK/at-file.env"
echo "secret PLAY_SERVICE_ACCOUNT_JSON@file=$MULTILINE_JSON_FILE" >"$AT_FILE_ENV"
: >"$GH_LOG"
out=$(FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --apply --yes --from-env-file "$AT_FILE_ENV" 2>&1)
rc=$?
check "--apply --yes with an @file entry exits 0" "0" "$rc"
MULTILINE_STDIN_LOGGED="$(grep -v '^ARGV' "$GH_LOG")"
check_contains "the 3-line JSON reached gh's stdin with its first line intact" '{' "$MULTILINE_STDIN_LOGGED"
check_contains "...and its middle line" '"a": 1' "$MULTILINE_STDIN_LOGGED"
check_contains "...and its last line" '}' "$MULTILINE_STDIN_LOGGED"

APPLY_ENV_FILE="$WORK/apply.env"
SECRET_VALUE="s3cr3t-value-that-must-never-appear-in-argv"
cat >"$APPLY_ENV_FILE" <<EOF
variable IOS_BUNDLE_ID=com.example.app
secret ASC_KEY_ID=$SECRET_VALUE
variable IOS_SCHEME=App
EOF

: >"$GH_LOG"
out=$(FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --apply --yes --from-env-file "$APPLY_ENV_FILE" 2>&1)
rc=$?
check "--apply --yes on all-good names exits 0" "0" "$rc"
check "the secret value never appears in gh.log's ARGV lines" "0" "$(grep '^ARGV' "$GH_LOG" | grep -cF "$SECRET_VALUE")"
check "the secret value appears in gh.log's STDIN lines" "1" "$(grep -v '^ARGV' "$GH_LOG" | grep -cF "$SECRET_VALUE")"

STOP_ENV_FILE="$WORK/stop.env"
cat >"$STOP_ENV_FILE" <<EOF
variable IOS_BUNDLE_ID=com.example.app
variable IOS_SCHEME=fails-here
variable ANDROID_PACKAGE=com.example.app
EOF
: >"$GH_LOG"
out=$(FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" FAKE_GH_FAIL_ON="IOS_SCHEME" \
  "$PUSH_TO_GITHUB" --apply --yes --from-env-file "$STOP_ENV_FILE" 2>&1)
rc=$?
check "a gh failure mid-apply exits 1" "1" "$rc"
check_contains "the name before the failure was set" "set: IOS_BUNDLE_ID" "$out"
check_not_contains "the name after the failure was never attempted (stdout)" "ANDROID_PACKAGE" "$out"
check_not_contains "the name after the failure has no gh.log entry at all" "ANDROID_PACKAGE" "$(cat "$GH_LOG")"

# new-upload-keystore.sh's own stdout is a valid env file.
if [ "$HAVE_REAL_KEYTOOL" -eq 1 ] && [ -s "$NEW_UPLOAD_ENV_FILE" ]; then
  : >"$GH_LOG"
  out=$(FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
    "$PUSH_TO_GITHUB" --plan --from-env-file "$NEW_UPLOAD_ENV_FILE" 2>&1)
  check "new-upload-keystore.sh's stdout parses cleanly as a push-to-github.sh env file" "0" "$?"
fi

echo
echo "== push-to-github.sh --verify (C1 exit polarity, I6 toggle map)"

VARS_NOTHING_ON="$WORK/vars-nothing-on.json"
node -e 'console.log(JSON.stringify(
  ["IOS_SIGNING_ENABLED","ANDROID_SIGNING_ENABLED","STORE_UPLOADS_ENABLED","STORE_METADATA_SYNC_ENABLED","OTA_ENABLED"]
    .map((n)=>({name:n,value:"false"}))
))' >"$VARS_NOTHING_ON"
out=$(FAKE_GH_VARS="$VARS_NOTHING_ON" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" "$PUSH_TO_GITHUB" --verify 2>&1)
check "--verify with no toggle on exits 3 (nothing to verify)" "3" "$?"

VARS_OTA_ON_SATISFIED="$WORK/vars-ota-on-satisfied.json"
node -e 'console.log(JSON.stringify([
  {name:"OTA_ENABLED",value:"true"},
  {name:"OTA_CLI_VERSION",value:"1.2.3"},
  {name:"EXPO_UPDATES_URL",value:"https://updates.example.com"}
]))' >"$VARS_OTA_ON_SATISFIED"
SECRETS_OTA_SATISFIED="$WORK/secrets-ota-satisfied.json"
echo '[{"name":"OTA_PUBLISH_TOKEN"}]' >"$SECRETS_OTA_SATISFIED"
out=$(FAKE_GH_VARS="$VARS_OTA_ON_SATISFIED" FAKE_GH_SECRETS="$SECRETS_OTA_SATISFIED" GH_LOG="$GH_LOG" "$PUSH_TO_GITHUB" --verify 2>&1)
check "--verify with a satisfied toggle exits 0" "0" "$?"

VARS_OTA_ON="$WORK/vars-ota-on.json"
echo '[{"name":"OTA_ENABLED","value":"true"}]' >"$VARS_OTA_ON"
out=$(FAKE_GH_VARS="$VARS_OTA_ON" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" "$PUSH_TO_GITHUB" --verify 2>&1)
check "--verify with an unsatisfied toggle exits 1" "1" "$?"
check_contains "...and reports what is missing" "missing:" "$out"

echo "I6: MATCH_GIT_BASIC_AUTHORIZATION is a warn under IOS_SIGNING_ENABLED, not a hard requirement"
VARS_IOS_SIGNING_ON="$WORK/vars-ios-signing-on.json"
echo '[{"name":"IOS_SIGNING_ENABLED","value":"true"}]' >"$VARS_IOS_SIGNING_ON"
SECRETS_IOS_SIGNING_SATISFIED="$WORK/secrets-ios-signing-satisfied.json"
echo '[{"name":"MATCH_PASSWORD"},{"name":"MATCH_GIT_URL"},{"name":"ASC_KEY_ID"},{"name":"ASC_ISSUER_ID"},{"name":"ASC_KEY_P8_BASE64"}]' >"$SECRETS_IOS_SIGNING_SATISFIED"
out=$(FAKE_GH_VARS="$VARS_IOS_SIGNING_ON" FAKE_GH_SECRETS="$SECRETS_IOS_SIGNING_SATISFIED" GH_LOG="$GH_LOG" "$PUSH_TO_GITHUB" --verify 2>&1)
rc=$?
check "IOS_SIGNING_ENABLED with the hard set satisfied still exits 0" "0" "$rc"
check_contains "...but warns about the missing basic-auth header" "WARN: MATCH_GIT_BASIC_AUTHORIZATION" "$out"

echo "I6: ANDROID_UPLOAD_CERT_SHA256 is a warn under ANDROID_SIGNING_ENABLED (signature gate degrades to skip)"
VARS_ANDROID_SIGNING_ON="$WORK/vars-android-signing-on.json"
echo '[{"name":"ANDROID_SIGNING_ENABLED","value":"true"}]' >"$VARS_ANDROID_SIGNING_ON"
SECRETS_ANDROID_SIGNING_SATISFIED="$WORK/secrets-android-signing-satisfied.json"
echo '[{"name":"ANDROID_UPLOAD_KEYSTORE_BASE64"},{"name":"ANDROID_UPLOAD_KEYSTORE_PASSWORD"},{"name":"ANDROID_UPLOAD_KEY_ALIAS"},{"name":"ANDROID_UPLOAD_KEY_PASSWORD"}]' >"$SECRETS_ANDROID_SIGNING_SATISFIED"
out=$(FAKE_GH_VARS="$VARS_ANDROID_SIGNING_ON" FAKE_GH_SECRETS="$SECRETS_ANDROID_SIGNING_SATISFIED" GH_LOG="$GH_LOG" "$PUSH_TO_GITHUB" --verify 2>&1)
rc=$?
check "ANDROID_SIGNING_ENABLED with the hard set satisfied still exits 0" "0" "$rc"
check_contains "...but warns the signature gate degrades to skip" "WARN: ANDROID_UPLOAD_CERT_SHA256" "$out"
check_contains "...naming the degrade explicitly" "degrades to 'skip'" "$out"

echo "I6: every toggle in TOGGLES_TABLE, exercised generically"
TOGGLE_LINES="$(sed -n '/^TOGGLES_TABLE="$/,/^"$/p' "$PUSH_TO_GITHUB" | sed '1d;$d')"
while IFS='|' read -r toggle needs; do
  [ -n "$toggle" ] || continue
  VARS_TOGGLE_ONLY="$WORK/vars-toggle-only-$toggle.json"
  node -e 'console.log(JSON.stringify([{name:process.argv[1],value:"true"}]))' "$toggle" >"$VARS_TOGGLE_ONLY"
  out=$(FAKE_GH_VARS="$VARS_TOGGLE_ONLY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" "$PUSH_TO_GITHUB" --verify 2>&1)
  rc=$?
  needed_count=0
  for _n in $needs; do needed_count=$((needed_count + 1)); done
  missing_count=$(printf '%s\n' "$out" | grep -c '^missing:')
  check "verify: $toggle=true alone exits 1" "1" "$rc"
  check "verify: $toggle=true reports all $needed_count required names missing" "$needed_count" "$missing_count"
done <<<"$TOGGLE_LINES"

echo
echo "== push-to-github.sh: a failing gh list is fatal, not an empty list"

# I4: with no listing, a name that is already set cannot be told from one
# that is missing - reporting everything missing (--plan) or "nothing to
# verify" (--verify) would both be lies.
GHFAIL_DIR="$WORK/ghfail"
mkdir -p "$GHFAIL_DIR"
cat >"$GHFAIL_DIR/gh" <<'FAKE_GH_FAIL'
#!/bin/bash
echo "gh: could not determine the repository" >&2
exit 1
FAKE_GH_FAIL
chmod +x "$GHFAIL_DIR/gh"

out=$(PATH="$GHFAIL_DIR:$PATH" "$PUSH_TO_GITHUB" --plan 2>&1)
rc=$?
check "--plan with a failing gh exits 1" "1" "$rc"
check_contains "...saying it cannot tell set from missing" "FATAL: gh variable list failed - cannot tell set from missing" "$out"
check_not_contains "...and reports nothing as missing" "missing" "$(printf '%s\n' "$out" | grep -v 'cannot tell set from missing')"

out=$(PATH="$GHFAIL_DIR:$PATH" "$PUSH_TO_GITHUB" --verify 2>&1)
rc=$?
check "--verify with a failing gh exits 1 (not 3)" "1" "$rc"
check_contains "...with the same fatal message" "cannot tell set from missing" "$out"

echo
echo "== push-to-github.sh: credential paths git could track are refused"

# I6: the same rule new-upload-keystore.sh applies to the files it writes -
# an env file (or an @file= target) inside a repository with no ignore rule
# covering it is one `git add -A` away from a committed credential.
PUSH_TRACKED_REPO="$WORK/push-tracked-repo"
mkdir -p "$PUSH_TRACKED_REPO/ignored" "$PUSH_TRACKED_REPO/tracked"
git init -q "$PUSH_TRACKED_REPO"
git -C "$PUSH_TRACKED_REPO" config user.email t@example.com
git -C "$PUSH_TRACKED_REPO" config user.name t
printf 'ignored/\n' >"$PUSH_TRACKED_REPO/.gitignore"
git -C "$PUSH_TRACKED_REPO" add .gitignore
git -C "$PUSH_TRACKED_REPO" commit -qm init

printf 'variable IOS_BUNDLE_ID=com.acme.app\n' >"$PUSH_TRACKED_REPO/tracked/creds.env"
out=$(FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --plan --from-env-file "$PUSH_TRACKED_REPO/tracked/creds.env" 2>&1)
rc=$?
check "an env file inside a repo with no ignore rule is refused" "2" "$rc"
check_contains "...naming the path" "tracked/creds.env" "$out"

printf 'variable IOS_BUNDLE_ID=com.acme.app\n' >"$PUSH_TRACKED_REPO/ignored/creds.env"
FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --plan --from-env-file "$PUSH_TRACKED_REPO/ignored/creds.env" >/dev/null 2>&1
check "the same env file under a .gitignore'd dir is accepted" "0" "$?"

printf 'not-really-a-key\n' >"$PUSH_TRACKED_REPO/tracked/play.json"
printf 'secret PLAY_SERVICE_ACCOUNT_JSON@file=%s\n' "$PUSH_TRACKED_REPO/tracked/play.json" \
  >"$PUSH_TRACKED_REPO/ignored/at-file.env"
out=$(FAKE_GH_VARS="$VARS_EMPTY" FAKE_GH_SECRETS="$SECRETS_EMPTY" GH_LOG="$GH_LOG" \
  "$PUSH_TO_GITHUB" --plan --from-env-file "$PUSH_TRACKED_REPO/ignored/at-file.env" 2>&1)
rc=$?
check "an @file= path git could track is refused too" "2" "$rc"
check_contains "...naming that path" "tracked/play.json" "$out"

echo
echo "== the class table matches docs/release-runbook.md and .github/workflows"
if [ -f "$RUNBOOK" ] && [ -d "$APP_REPO_ROOT/.github/workflows" ]; then

RUNBOOK_VAR_CELLS="$(awk '
/^\| Variable \|/{invar=1; next}
/^\| Secret \|/{invar=0; next}
/^### Why the hop is a dispatch/{exit}
invar && /^\| `/{n=split($0,f,"|"); print f[2]}
' "$RUNBOOK")"
# shellcheck disable=SC2016 # the pattern is a literal regex, not a shell expansion
RUNBOOK_VARS="$(printf '%s\n' "$RUNBOOK_VAR_CELLS" | grep -oE '`[A-Z][A-Z0-9_]*`' | tr -d '`' | sort -u)"

RUNBOOK_SECRET_CELLS="$(awk '
/^\| Secret \|/{insec=1; next}
/^### Why the hop is a dispatch/{exit}
insec && /^\| `/{n=split($0,f,"|"); print f[2]}
' "$RUNBOOK")"
# shellcheck disable=SC2016 # the pattern is a literal regex, not a shell expansion
RUNBOOK_SECRETS="$(printf '%s\n' "$RUNBOOK_SECRET_CELLS" | grep -oE '`[A-Z][A-Z0-9_]*`' | tr -d '`' | sort -u)"

SCRIPT_VARS="$(sed -nE 's/^VARIABLE_NAMES="(.*)"$/\1/p' "$PUSH_TO_GITHUB" | tr ' ' '\n' | sort -u)"
SCRIPT_SECRETS="$(sed -nE 's/^SECRET_NAMES="(.*)"$/\1/p' "$PUSH_TO_GITHUB" | tr ' ' '\n' | sort -u)"

check "the script's variable names equal the runbook's variable table" "" "$(diff <(printf '%s\n' "$RUNBOOK_VARS") <(printf '%s\n' "$SCRIPT_VARS"))"
check "the script's secret names equal the runbook's secret table (union with APP_REVIEW_*/OPENAI_API_KEY mentions)" "" \
  "$(diff <(printf '%s\n' "$RUNBOOK_SECRETS") <(printf '%s\n' "$SCRIPT_SECRETS"))"

# The workflows are where a name is introduced, so they close the triangle:
# a new vars.X/secrets.X fails here until the script lists it, and the two
# checks above then demand its runbook row. GITHUB_TOKEN is GitHub's own.
WORKFLOWS_DIR="$APP_REPO_ROOT/.github/workflows"
WORKFLOW_VARS="$(grep -rhoE --include='*.yml' --include='*.yaml' 'vars\.[A-Z][A-Z0-9_]*' "$WORKFLOWS_DIR" | sed 's/^vars\.//' | sort -u)"
WORKFLOW_SECRETS="$(grep -rhoE --include='*.yml' --include='*.yaml' 'secrets\.[A-Z][A-Z0-9_]*' "$WORKFLOWS_DIR" | sed 's/^secrets\.//' | grep -vx 'GITHUB_TOKEN' | sort -u)"

check "the script's variable names equal every vars.* the workflows read" "" "$(diff <(printf '%s\n' "$WORKFLOW_VARS") <(printf '%s\n' "$SCRIPT_VARS"))"
check "the script's secret names equal every secrets.* the workflows read" "" "$(diff <(printf '%s\n' "$WORKFLOW_SECRETS") <(printf '%s\n' "$SCRIPT_SECRETS"))"
else
  skip "the class table vs an app's runbook and workflows (set APP_REPO_ROOT to an app checkout)"
fi

echo
echo "== no 'nuke' outside a 'never'-comment"

EXPECTED_SCRIPTS="validate-asc-key.sh validate-keystore.sh validate-play-json.sh validate-match-repo.sh validate-huawei-credentials.sh new-upload-keystore.sh push-to-github.sh"
ALL_SCRIPTS_EXIST=1
for name in $EXPECTED_SCRIPTS; do
  [ -f "$SKILL_DIR/scripts/$name" ] || ALL_SCRIPTS_EXIST=0
done
check "all seven script files exist" "yes" "$([ "$ALL_SCRIPTS_EXIST" -eq 1 ] && echo yes || echo no)"

NUKE_VIOLATIONS=0
for f in "$SKILL_DIR"/scripts/*.sh; do
  while IFS= read -r line; do
    case "$line" in
      *nuke*)
        trimmed="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//')"
        case "$trimmed" in
          '#'*never*) : ;;
          *) NUKE_VIOLATIONS=$((NUKE_VIOLATIONS + 1)) ;;
        esac
        ;;
    esac
  done <"$f"
done
check "no script contains 'nuke' outside a comment line that also says 'never'" "0" "$NUKE_VIOLATIONS"

echo
echo "== SKILL.md"

check "SKILL.md names validate-asc-key.sh" "yes" "$(grep -qF 'validate-asc-key.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names validate-keystore.sh" "yes" "$(grep -qF 'validate-keystore.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names validate-play-json.sh" "yes" "$(grep -qF 'validate-play-json.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names validate-match-repo.sh" "yes" "$(grep -qF 'validate-match-repo.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names validate-huawei-credentials.sh" "yes" "$(grep -qF 'validate-huawei-credentials.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names new-upload-keystore.sh" "yes" "$(grep -qF 'new-upload-keystore.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names push-to-github.sh" "yes" "$(grep -qF 'push-to-github.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md mentions match nuke as a red flag" "yes" "$(grep -qF 'match nuke' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md documents the @file env-file line form" "yes" "$(grep -qF '@file=' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md says where production_match_git_url comes from" "yes" \
  "$(grep -qF 'production_match_git_url' "$SKILL_MD" && grep -qF 'apple-match-repo' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md documents the basic-auth header as an environment variable" "yes" \
  "$(grep -qF 'MATCH_GIT_BASIC_AUTHORIZATION' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md's env-file example keeps the file out of the repository" "yes" \
  "$(# shellcheck disable=SC2016 # the single-quoted "$TMPDIR/creds.env" is the literal the SKILL.md must contain
  grep -qF '"$TMPDIR/creds.env"' "$SKILL_MD" && echo yes || echo no)"

# I2: the cred-* ids this skill names and the cred-* ids in the checklist
# vocabulary are the same set, in both directions.
STATE_SH="$(cd "$SKILL_DIR/../store-setup/scripts" && pwd)/state.sh"
VOCABULARY_CRED_IDS="$("$STATE_SH" --list-steps | grep -E '^cred-' | sort -u)"
SKILL_MD_CRED_IDS="$(grep -ohE 'cred-[a-z0-9-]+' "$SKILL_MD" | sort -u)"
check "every cred-* id in SKILL.md is in state.sh --list-steps, and every one of those is in SKILL.md" "" \
  "$(diff <(printf '%s\n' "$VOCABULARY_CRED_IDS") <(printf '%s\n' "$SKILL_MD_CRED_IDS"))"

# I5: allowed-tools is a comma-separated list of Bash(prefix:*) patterns -
# space-separated entries or `Bash(cmd *)` globs are not what Claude Code
# parses.
ALLOWED_TOOLS_LINE="$(grep -m1 '^allowed-tools:' "$SKILL_MD")"
check "SKILL.md's allowed-tools line is comma-separated" "yes" \
  "$(printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF ',' && echo yes || echo no)"
check "SKILL.md's allowed-tools line uses the :* prefix form" "yes" \
  "$(printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF ':*' && echo yes || echo no)"

echo
echo "-------------------------------------"
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
