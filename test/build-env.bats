#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/gh_env" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_ENV"
}

publish() { run bash "$REPO_ROOT/scripts/release/build-env.sh"; }

# gh_env_keys - the variable names the runner would take out of $GITHUB_ENV,
# parsed the way the runner parses it: a `KEY=value` line, or `KEY<<DELIM` up to
# a line that is exactly DELIM. Everything between the delimiters is value, no
# matter what it looks like - which is the whole point of the heredoc form.
gh_env_keys() {
  awk '
    delim != "" { if ($0 == delim) delim = ""; next }
    /^[A-Za-z_][A-Za-z0-9_]*<</ { i = index($0, "<<"); print substr($0, 1, i - 1); delim = substr($0, i + 2); next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ { i = index($0, "="); print substr($0, 1, i - 1); next }
  ' "$GITHUB_ENV"
}

@test "publishes valid keys to GITHUB_ENV" {
  WORKFLOWS_BUILD_ENV='{"OTA_ENABLED":"true","EXPO_PUBLIC_API_URL":"https://x","STORE_NOTES_INCLUDE_CHANGELOG":true}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'OTA_ENABLED=true' "$GITHUB_ENV" || fail "OTA_ENABLED missing: $(cat "$GITHUB_ENV")"
  grep -qx 'EXPO_PUBLIC_API_URL=https://x' "$GITHUB_ENV" || fail "EXPO_PUBLIC_API_URL missing: $(cat "$GITHUB_ENV")"
  # A JSON boolean is coerced to the string GitHub's env file needs.
  grep -qx 'STORE_NOTES_INCLUDE_CHANGELOG=true' "$GITHUB_ENV" || fail "boolean not coerced: $(cat "$GITHUB_ENV")"
}

@test "logs key names but never values" {
  WORKFLOWS_BUILD_ENV='{"EXPO_UPDATES_URL":"https://updates.example.test/very-distinctive"}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "EXPO_UPDATES_URL" || fail "the key was not logged: $output"
  not_contains "$output" "very-distinctive" || fail "the value leaked into the log: $output"
}

@test "an empty object is a no-op, not an error" {
  WORKFLOWS_BUILD_ENV='{}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "wrote something for an empty build-env: $(cat "$GITHUB_ENV")"
}

@test "a lower-case or malformed key is rejected" {
  WORKFLOWS_BUILD_ENV='{"ota_enabled":"true"}' publish
  [ "$status" -ne 0 ] || fail "accepted a lower-case key: $output"
  contains "$output" "not an upper-case env name" || fail "unexpected message: $output"
  WORKFLOWS_BUILD_ENV='{"1BAD":"x"}' publish
  [ "$status" -ne 0 ] || fail "accepted a key starting with a digit: $output"
}

# build-env is a workflow input: GitHub neither masks it nor hides it from the
# run's parameters, so a credential passed through it is public.
@test "a key that looks like a credential is refused" {
  for k in API_KEY GITHUB_TOKEN ANDROID_UPLOAD_KEY_PASSWORD SOME_SECRET DB_CREDENTIALS; do
    WORKFLOWS_BUILD_ENV="{\"$k\":\"x\"}" publish
    [ "$status" -ne 0 ] || fail "accepted the credential-looking key $k: $output"
    contains "$output" "looks like a credential" || fail "unexpected message for $k: $output"
  done
}

@test "a known credential name is refused even though it does not match the suffix rule" {
  WORKFLOWS_BUILD_ENV='{"PLAY_SERVICE_ACCOUNT_JSON":"{}"}' publish
  [ "$status" -ne 0 ] || fail "accepted PLAY_SERVICE_ACCOUNT_JSON: $output"
  contains "$output" "looks like a credential" || fail "unexpected message: $output"
}

@test "a non-object or non-scalar value is rejected" {
  WORKFLOWS_BUILD_ENV='["a"]' publish
  [ "$status" -ne 0 ] || fail "accepted an array: $output"
  contains "$output" "flat JSON object" || fail "unexpected message: $output"
  WORKFLOWS_BUILD_ENV='{"A":{"b":1}}' publish
  [ "$status" -ne 0 ] || fail "accepted a nested object: $output"
  contains "$output" "must be a scalar" || fail "unexpected message: $output"
  WORKFLOWS_BUILD_ENV='not json' publish
  [ "$status" -ne 0 ] || fail "accepted invalid JSON: $output"
  contains "$output" "not valid JSON" || fail "unexpected message: $output"
}

@test "the scratch env file does not survive, on either path" {
  WORKFLOWS_BUILD_ENV='{"OTA_ENABLED":"true"}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -f "$RUNNER_TEMP/workflows-build-env.env" ] || fail "left a scratch file behind"
  WORKFLOWS_BUILD_ENV='{"API_KEY":"x"}' publish
  [ "$status" -ne 0 ] || fail "accepted a credential key: $output"
  [ ! -f "$RUNNER_TEMP/workflows-build-env.env" ] || fail "left a scratch file behind after a rejection"
}

# C1: `KEY=value` is line-based, so a value carrying a newline used to write a
# second line that the runner reads as *another* variable - `PATH` included, in
# a job that also holds signing credentials.
@test "a value containing a newline cannot inject a second variable" {
  WORKFLOWS_BUILD_ENV='{"EXPO_PUBLIC_APP_NAME":"a\nPATH=/evil"}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  keys="$(gh_env_keys)"
  [ "$keys" = "EXPO_PUBLIC_APP_NAME" ] || fail "GITHUB_ENV yields the wrong variables ($keys): $(cat "$GITHUB_ENV")"
  grep -q '^EXPO_PUBLIC_APP_NAME<<__workflows_eof_' "$GITHUB_ENV" \
    || fail "the multi-line value was not written in the heredoc form: $(cat "$GITHUB_ENV")"
  # The value itself is intact - it is quoted, not truncated.
  grep -qx 'PATH=/evil' "$GITHUB_ENV" || fail "the value was mangled: $(cat "$GITHUB_ENV")"
}

# The validator hands the reader key/value pairs separated by NUL, so a NUL
# inside a value used to end it and start a pair of the caller's choosing -
# PATH, or the WORKFLOWS_FINGERPRINT_IOS the OTA gate trusts - past every name rule.
@test "a value containing a NUL cannot inject a second variable" {
  for injected in PATH WORKFLOWS_FINGERPRINT_IOS; do
    : > "$GITHUB_ENV"
    WORKFLOWS_BUILD_ENV="{\"APP\":\"a\\u0000$injected\\u0000/evil\"}" publish
    [ "$status" -ne 0 ] || fail "accepted a NUL that injects $injected: $output"
    contains "$output" "contains a NUL character" || fail "unexpected message for $injected: $output"
    [ ! -s "$GITHUB_ENV" ] || fail "wrote to GITHUB_ENV anyway: $(cat "$GITHUB_ENV")"
  done
}

@test "a single-line value still uses the plain form" {
  WORKFLOWS_BUILD_ENV='{"OTA_ENABLED":"true"}' publish
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'OTA_ENABLED=true' "$GITHUB_ENV" || fail "not the plain form: $(cat "$GITHUB_ENV")"
  [ "$(wc -l < "$GITHUB_ENV" | tr -d ' ')" -eq 1 ] || fail "wrote more than one line: $(cat "$GITHUB_ENV")"
}

# I3: build-env is published before fingerprint.sh runs, so WORKFLOWS_FINGERPRINT_* would hand
# the OTA gate a caller-supplied constant to compare its baseline against.
@test "a key owned by the family or the runner is refused" {
  for k in WORKFLOWS_FINGERPRINT_IOS WORKFLOWS_ASSETS_DIR GITHUB_REPOSITORY RUNNER_TEMP ACTIONS_STEP_DEBUG PATH HOME LD_PRELOAD DYLD_INSERT_LIBRARIES NODE_OPTIONS; do
    WORKFLOWS_BUILD_ENV="{\"$k\":\"x\"}" publish
    [ "$status" -ne 0 ] || fail "accepted the reserved key $k: $output"
    contains "$output" "is reserved by shared-workflows" || fail "unexpected message for $k: $output"
    [ ! -s "$GITHUB_ENV" ] || fail "wrote $k to GITHUB_ENV anyway: $(cat "$GITHUB_ENV")"
  done
}

# A credential-looking name that is also reserved must still say "credential":
# that is the more urgent of the two diagnoses.
@test "GITHUB_TOKEN is refused as a credential, not as a reserved name" {
  WORKFLOWS_BUILD_ENV='{"GITHUB_TOKEN":"x"}' publish
  [ "$status" -ne 0 ] || fail "accepted GITHUB_TOKEN: $output"
  contains "$output" "looks like a credential" || fail "unexpected message: $output"
}
