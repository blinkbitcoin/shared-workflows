#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# env-json.sh is build-env.sh's near-twin (same validator shape, same
# $GITHUB_ENV writer, a looser key rule), so the cases here mirror
# test/build-env.bats deliberately: the two files carry the same holes when they
# drift, and mirrored tests are what notices.
load test_helper

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/gh_env" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_ENV"
}

publish() { run bash "$REPO_ROOT/scripts/release/env-json.sh"; }

# See test/build-env.bats: the runner's own parse of $GITHUB_ENV.
gh_env_keys() {
  awk '
    delim != "" { if ($0 == delim) delim = ""; next }
    /^[A-Za-z_][A-Za-z0-9_]*<</ { i = index($0, "<<"); print substr($0, 1, i - 1); delim = substr($0, i + 2); next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ { i = index($0, "="); print substr($0, 1, i - 1); next }
  ' "$GITHUB_ENV"
}

@test "publishes keys to GITHUB_ENV, coercing scalars" {
  WORKFLOWS_ENV_JSON='{"APP_VARIANT":"beta","track":"internal","PHASED":true,"N":3,"EMPTY":null}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'APP_VARIANT=beta' "$GITHUB_ENV" || fail "APP_VARIANT missing: $(cat "$GITHUB_ENV")"
  grep -qx 'track=internal' "$GITHUB_ENV" || fail "a lower-case key was rejected: $(cat "$GITHUB_ENV")"
  grep -qx 'PHASED=true' "$GITHUB_ENV" || fail "boolean not coerced: $(cat "$GITHUB_ENV")"
  grep -qx 'N=3' "$GITHUB_ENV" || fail "number not coerced: $(cat "$GITHUB_ENV")"
  grep -qx 'EMPTY=' "$GITHUB_ENV" || fail "null not coerced to empty: $(cat "$GITHUB_ENV")"
}

@test "an empty object is a no-op, not an error" {
  WORKFLOWS_ENV_JSON='{}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "wrote something for an empty object: $(cat "$GITHUB_ENV")"
  WORKFLOWS_ENV_JSON='' publish
  [ "$status" -eq 0 ] || fail "an unset value is not a no-op: $output"
}

@test "a malformed key is rejected" {
  WORKFLOWS_ENV_JSON='{"1BAD":"x"}' publish
  [ "$status" -ne 0 ] || fail "accepted a key starting with a digit: $output"
  contains "$output" "not a valid env name" || fail "unexpected message: $output"
  WORKFLOWS_ENV_JSON='{"A B":"x"}' publish
  [ "$status" -ne 0 ] || fail "accepted a key with a space: $output"
}

@test "a lower-case key is still accepted - that difference from build-env is by design" {
  # These keys reach a fastlane lane, whose own option names (`track`, `lane`)
  # are lower-case, and docs/consumer-guide.md says so. Sharing the validator
  # with build-env must not quietly take that away.
  WORKFLOWS_ENV_JSON='{"track":"internal"}' publish
  [ "$status" -eq 0 ] || fail "rejected a lower-case key: $output"
  grep -qx 'track=internal' "$GITHUB_ENV" || fail "track missing: $(cat "$GITHUB_ENV")"
}

@test "a lower-case credential name is refused too" {
  # The trap in allowing lower-case: a case-sensitive credential rule would wave
  # `sentry_auth_token` straight through the check that exists to stop it. Keys
  # are upper-cased before the credential and reserved rules are applied.
  WORKFLOWS_ENV_JSON='{"sentry_auth_token":"x"}' publish
  [ "$status" -ne 0 ] || fail "published a lower-case credential name: $output"
  contains "$output" "looks like a credential" || fail "unexpected message: $output"
  WORKFLOWS_ENV_JSON='{"workflows_fp_ios":"deadbeef"}' publish
  [ "$status" -ne 0 ] || fail "published a lower-case reserved name: $output"
  contains "$output" "reserved" || fail "unexpected message: $output"
}

# --- credential names, ported from build-env.bats ----------------------------
#
# These are the assertions env-json.sh never had. Its header claimed the two
# inputs could not drift because the same tests covered both; in fact this file
# had no credential case at all, so {"SENTRY_AUTH_TOKEN": "..."} was published
# straight into $GITHUB_ENV from a workflow input GitHub does not mask.

@test "a key that looks like a credential is refused" {
  for k in SENTRY_AUTH_TOKEN SOME_API_KEY DB_PASSWORD MY_SECRET A_PASSPHRASE X_CREDENTIALS X_CREDENTIAL; do
    WORKFLOWS_ENV_JSON="{\"$k\":\"x\"}" publish
    [ "$status" -ne 0 ] || fail "published $k, a credential-shaped name: $output"
    contains "$output" "looks like a credential" || fail "unexpected message for $k: $output"
    [ ! -s "$GITHUB_ENV" ] || fail "$k reached GITHUB_ENV: $(cat "$GITHUB_ENV")"
  done
}

@test "a known credential name is refused even though it does not match the suffix rule" {
  for k in PLAY_SERVICE_ACCOUNT_JSON ASC_KEY_P8_BASE64 ANDROID_UPLOAD_KEYSTORE_BASE64 MATCH_GIT_BASIC_AUTHORIZATION; do
    WORKFLOWS_ENV_JSON="{\"$k\":\"x\"}" publish
    [ "$status" -ne 0 ] || fail "published $k: $output"
    [ ! -s "$GITHUB_ENV" ] || fail "$k reached GITHUB_ENV: $(cat "$GITHUB_ENV")"
  done
}

# The single mechanism behind the "these cannot drift" claim in both headers.
@test "both inputs are validated by the one shared validator" {
  grep -q 'env-validate.mjs' "$REPO_ROOT/scripts/release/env-json.sh" \
    || fail "env-json.sh no longer calls the shared validator"
  grep -q 'env-validate.mjs' "$REPO_ROOT/scripts/lib/build-env.sh" \
    || fail "build-env.sh no longer calls the shared validator"
}

@test "a non-object or non-scalar value is rejected" {
  WORKFLOWS_ENV_JSON='["a"]' publish
  [ "$status" -ne 0 ] || fail "accepted an array: $output"
  contains "$output" "flat JSON object" || fail "unexpected message: $output"
  WORKFLOWS_ENV_JSON='{"A":{"b":1}}' publish
  [ "$status" -ne 0 ] || fail "accepted a nested object: $output"
  contains "$output" "must be a scalar" || fail "unexpected message: $output"
  WORKFLOWS_ENV_JSON='not json' publish
  [ "$status" -ne 0 ] || fail "accepted invalid JSON: $output"
  contains "$output" "not valid JSON" || fail "unexpected message: $output"
}

# C1, the env-json half.
@test "a value containing a newline cannot inject a second variable" {
  WORKFLOWS_ENV_JSON='{"APP_VARIANT":"a\nPATH=/evil"}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  keys="$(gh_env_keys)"
  [ "$keys" = "APP_VARIANT" ] || fail "GITHUB_ENV yields the wrong variables ($keys): $(cat "$GITHUB_ENV")"
  grep -q '^APP_VARIANT<<__workflows_eof_' "$GITHUB_ENV" \
    || fail "the multi-line value was not written in the heredoc form: $(cat "$GITHUB_ENV")"
  grep -qx 'PATH=/evil' "$GITHUB_ENV" || fail "the value was mangled: $(cat "$GITHUB_ENV")"
}

# The NUL half of C1: see test/build-env.bats. A lower-case key is allowed here,
# so the case covers both name modes of the one validator.
@test "a value containing a NUL cannot inject a second variable" {
  for injected in PATH WORKFLOWS_FINGERPRINT_IOS; do
    : > "$GITHUB_ENV"
    WORKFLOWS_ENV_JSON="{\"track\":\"a\\u0000$injected\\u0000/evil\"}" publish
    [ "$status" -ne 0 ] || fail "accepted a NUL that injects $injected: $output"
    contains "$output" "contains a NUL character" || fail "unexpected message for $injected: $output"
    [ ! -s "$GITHUB_ENV" ] || fail "wrote to GITHUB_ENV anyway: $(cat "$GITHUB_ENV")"
  done
}

# I3, the env-json half: this input reaches $GITHUB_ENV just like build-env.
@test "a key owned by the family or the runner is refused" {
  for k in WORKFLOWS_FINGERPRINT_IOS WORKFLOWS_ASSETS_DIR GITHUB_REPOSITORY RUNNER_TEMP ACTIONS_STEP_DEBUG PATH HOME LD_PRELOAD NODE_OPTIONS; do
    WORKFLOWS_ENV_JSON="{\"$k\":\"x\"}" publish
    [ "$status" -ne 0 ] || fail "accepted the reserved key $k: $output"
    contains "$output" "is reserved by shared-workflows" || fail "unexpected message for $k: $output"
    [ ! -s "$GITHUB_ENV" ] || fail "wrote $k to GITHUB_ENV anyway: $(cat "$GITHUB_ENV")"
  done
}

@test "the scratch env file does not survive, on either path" {
  WORKFLOWS_ENV_JSON='{"APP_VARIANT":"beta"}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -f "$RUNNER_TEMP/workflows-env-json.env" ] || fail "left a scratch file behind"
  WORKFLOWS_ENV_JSON='{"A":{"b":1}}' publish
  [ "$status" -ne 0 ] || fail "accepted a nested object: $output"
  [ ! -f "$RUNNER_TEMP/workflows-env-json.env" ] || fail "left a scratch file behind after a rejection"
}
