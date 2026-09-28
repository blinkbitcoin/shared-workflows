#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# build-info.json is the one machine-readable record of what a release build is:
# the OTA gate compares its `fingerprint`, the store lanes read
# `version`/`buildNumber`, and it ships as a release asset. The schema is
# asserted key by key here because renaming one is a breaking change for all
# three readers.
load test_helper

setup() {
  ROOT="$BATS_TEST_TMPDIR/app"
  mkdir -p "$ROOT/node_modules/expo" "$ROOT/node_modules/react-native"
  # The declared ranges and the installed versions differ on purpose. That gap is
  # the whole point of these two fields, and a fixture where they matched would
  # pass against either implementation.
  cat > "$ROOT/package.json" <<'JSON'
{
  "name": "consumer",
  "dependencies": { "expo": "^54.0.0", "react-native": "0.81.4" }
}
JSON
  printf '{"name":"expo","version":"54.0.7"}\n' > "$ROOT/node_modules/expo/package.json"
  printf '{"name":"react-native","version":"0.81.9"}\n' > "$ROOT/node_modules/react-native/package.json"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=app
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_RELEASE_META_DIR="$BATS_TEST_TMPDIR/meta"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_ENV GITHUB_OUTPUT WORKFLOWS_SHA GITHUB_SHA WORKFLOWS_STAGE FINGERPRINT_IOS FINGERPRINT_ANDROID GITHUB_RUN_ID
  DEST="$WORKFLOWS_RELEASE_META_DIR/build-info.json"
}

build_info() { run bash "$REPO_ROOT/scripts/release/build-info.sh"; }
field() { node -e 'const i=require(process.argv[1]);const p=process.argv[2].split(".");let v=i;for(const k of p)v=v?.[k];console.log(v===undefined?"undefined":JSON.stringify(v))' "$DEST" "$1"; }

@test "writes the documented schema" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1042 WORKFLOWS_STAGE=beta WORKFLOWS_SHA=deadbeef \
    FINGERPRINT_IOS=fp-i FINGERPRINT_ANDROID=fp-a GITHUB_RUN_ID=99 build_info
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -f "$DEST" ] || fail "no build-info.json was written"
  [ "$(field sha)" = '"deadbeef"' ] || fail "wrong sha: $(cat "$DEST")"
  [ "$(field version)" = '"1.2.3"' ] || fail "wrong version: $(cat "$DEST")"
  # A number, not a string: the store lanes compare it numerically.
  [ "$(field buildNumber)" = '1042' ] || fail "buildNumber is not a number: $(cat "$DEST")"
  [ "$(field stage)" = '"beta"' ] || fail "wrong stage: $(cat "$DEST")"
  [ "$(field fingerprint.ios)" = '"fp-i"' ] || fail "wrong ios fingerprint: $(cat "$DEST")"
  [ "$(field fingerprint.android)" = '"fp-a"' ] || fail "wrong android fingerprint: $(cat "$DEST")"
  [ "$(field reactNative)" = '"0.81.9"' ] || fail "wrong reactNative: $(cat "$DEST")"
  [ "$(field workflowRunId)" = '"99"' ] || fail "wrong workflowRunId: $(cat "$DEST")"
  [ "$(field artifacts)" = '{}' ] || fail "artifacts is not an empty object: $(cat "$DEST")"
}

# The regression this pins: this copy used to read the *declared* range out of
# package.json and strip its operator, so it reported 54.0.0 for a build that
# actually ran on 54.0.7 - and the consumer's own copy of this record, which
# reads the installed version, disagreed with it on every such build. A
# provenance record must say what actually went into the build.
@test "expoSdk and reactNative are the installed versions, not the declared ranges" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 WORKFLOWS_SHA=x build_info
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field expoSdk)" = '"54.0.7"' ] || fail "expoSdk came from the range, not the install: $(cat "$DEST")"
  [ "$(field reactNative)" = '"0.81.9"' ] || fail "reactNative came from the range, not the install: $(cat "$DEST")"
}

@test "a package that is not installed gives null, not a failure" {
  rm -rf "$ROOT/node_modules/react-native"
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 WORKFLOWS_SHA=x build_info
  [ "$status" -eq 0 ] || fail "a missing package failed the release: $output"
  [ "$(field reactNative)" = 'null' ] || fail "reactNative is not null: $(cat "$DEST")"
  [ "$(field expoSdk)" = '"54.0.7"' ] || fail "the package that IS installed was lost too: $(cat "$DEST")"
}

@test "a consumer with nothing installed gives null, not a failure" {
  rm -rf "$ROOT/node_modules" "$ROOT/package.json"
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 WORKFLOWS_SHA=x build_info
  [ "$status" -eq 0 ] || fail "a consumer without package.json failed the release: $output"
  [ "$(field expoSdk)" = 'null' ] || fail "expoSdk is not null: $(cat "$DEST")"
  [ "$(field reactNative)" = 'null' ] || fail "reactNative is not null: $(cat "$DEST")"
}

@test "an unset fingerprint is null rather than an empty string" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 WORKFLOWS_SHA=x build_info
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field fingerprint.ios)" = 'null' ] || fail "ios fingerprint is not null: $(cat "$DEST")"
}

@test "the sha falls back to GITHUB_SHA when target-sha.sh did not run" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 GITHUB_SHA=fallbacksha build_info
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field sha)" = '"fallbacksha"' ] || fail "wrong sha: $(cat "$DEST")"
}

@test "the stage defaults to development" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 WORKFLOWS_SHA=x build_info
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field stage)" = '"development"' ] || fail "wrong default stage: $(cat "$DEST")"
}

@test "a missing version or build number is fatal, and names the script to run" {
  APP_BUILD_NUMBER=1 build_info
  [ "$status" -ne 0 ] || fail "wrote a build-info without a version: $output"
  contains "$output" "resolve-version.sh" || fail "unexpected message: $output"
  APP_VERSION=1.2.3 build_info
  [ "$status" -ne 0 ] || fail "wrote a build-info without a build number: $output"
  contains "$output" "resolve-version.sh" || fail "unexpected message: $output"
  [ ! -f "$DEST" ] || fail "wrote a build-info.json anyway"
}

# --- --standalone: a laptop, where no earlier step ran -------------------------

# A fake npx standing in for the consumer's @expo/fingerprint bin: it records
# its arguments and prints a JSON hash named after the platform it was asked for,
# or fails when WORKFLOWS_TEST_FINGERPRINT_STATUS says so.
stub_npx() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/npx-calls"
  : > "$CALLS"
  export WORKFLOWS_TEST_CALLS="$CALLS"
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
[ "${WORKFLOWS_TEST_FINGERPRINT_STATUS:-0}" = 0 ] || exit "$WORKFLOWS_TEST_FINGERPRINT_STATUS"
printf '{"hash":"computed-%s"}' "${!#}"
SH
  chmod +x "$STUB/npx"
  export PATH="$STUB:$PATH"
}

# The consumer as a git repository whose HEAD carries the tag v4.5.6.
tagged_repo() {
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" config user.email t@example.com
  git -C "$ROOT" config user.name t
  git -C "$ROOT" commit -q --allow-empty -m c
  git -C "$ROOT" tag v4.5.6
  unset RELEASE_PR_TITLE BUILD_NUMBER_OFFSET GITHUB_REF_NAME WORKFLOWS_RELEASE_SCOPE
}

@test "an unknown argument is fatal and names the one it accepts" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 run bash "$REPO_ROOT/scripts/release/build-info.sh" --stand-alone
  [ "$status" -ne 0 ] || fail "accepted an unknown argument: $output"
  contains "$output" "usage: build-info.sh [--standalone]" || fail "unexpected message: $output"
  [ ! -f "$DEST" ] || fail "wrote a build-info.json anyway"
}

@test "--standalone resolves the version and computes both fingerprints when none is given" {
  stub_npx
  tagged_repo
  WORKFLOWS_SHA=x run bash "$REPO_ROOT/scripts/release/build-info.sh" --standalone
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field version)" = '"4.5.6"' ] || fail "the version was not resolved: $(cat "$DEST")"
  # One first-parent commit plus the default offset of 1000.
  [ "$(field buildNumber)" = '1001' ] || fail "the build number was not resolved: $(cat "$DEST")"
  [ "$(field fingerprint.ios)" = '"computed-ios"' ] || fail "the ios fingerprint was not computed: $(cat "$DEST")"
  [ "$(field fingerprint.android)" = '"computed-android"' ] || fail "the android fingerprint was not computed: $(cat "$DEST")"
}

@test "--standalone keeps every value the environment already has, and computes nothing" {
  stub_npx
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=7 FINGERPRINT_IOS=fp-i FINGERPRINT_ANDROID=fp-a WORKFLOWS_SHA=x \
    run bash "$REPO_ROOT/scripts/release/build-info.sh" --standalone
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field version)" = '"1.2.3"' ] || fail "the given version was replaced: $(cat "$DEST")"
  [ "$(field buildNumber)" = '7' ] || fail "the given build number was replaced: $(cat "$DEST")"
  [ "$(field fingerprint.ios)" = '"fp-i"' ] || fail "the given ios fingerprint was replaced: $(cat "$DEST")"
  [ ! -s "$CALLS" ] || fail "the fingerprint CLI ran anyway: $(cat "$CALLS")"
}

@test "--standalone resolves the build number alone when only the version is given" {
  stub_npx
  tagged_repo
  APP_VERSION=9.9.9 FINGERPRINT_IOS=fp-i FINGERPRINT_ANDROID=fp-a WORKFLOWS_SHA=x \
    run bash "$REPO_ROOT/scripts/release/build-info.sh" --standalone
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field version)" = '"9.9.9"' ] || fail "the given version was replaced: $(cat "$DEST")"
  [ "$(field buildNumber)" = '1001' ] || fail "the build number was not resolved: $(cat "$DEST")"
}

@test "--standalone stops when the version cannot be resolved" {
  stub_npx
  # No git repository at all: resolve-version.sh cannot count commits.
  WORKFLOWS_SHA=x run bash "$REPO_ROOT/scripts/release/build-info.sh" --standalone
  [ "$status" -ne 0 ] || fail "wrote a build-info without a version: $output"
  contains "$output" "resolve-version.sh failed" || fail "unexpected message: $output"
  [ ! -f "$DEST" ] || fail "wrote a build-info.json anyway"
}

@test "--standalone stops when a fingerprint cannot be computed" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_STATUS=1 APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 WORKFLOWS_SHA=x \
    run bash "$REPO_ROOT/scripts/release/build-info.sh" --standalone
  [ "$status" -ne 0 ] || fail "wrote a build-info without a fingerprint: $output"
  contains "$output" "fingerprint:generate failed for ios" || fail "unexpected message: $output"
  [ ! -f "$DEST" ] || fail "wrote a build-info.json anyway"
}

@test "--standalone stops when only the android fingerprint cannot be computed" {
  stub_npx
  WORKFLOWS_TEST_FINGERPRINT_STATUS=1 APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 FINGERPRINT_IOS=fp-i WORKFLOWS_SHA=x \
    run bash "$REPO_ROOT/scripts/release/build-info.sh" --standalone
  [ "$status" -ne 0 ] || fail "wrote a build-info without an android fingerprint: $output"
  contains "$output" "fingerprint:generate failed for android" || fail "unexpected message: $output"
  [ ! -f "$DEST" ] || fail "wrote a build-info.json anyway"
}

# --- parity with the consumer's own copy ------------------------------------
#
# TWO scripts write build-info.json: this one (CI, with the fingerprints already
# computed by fingerprint.sh and the version already resolved) and the
# consumer's own scripts/release/build-info.sh (standalone, computing its own
# fingerprints and defaulting its own version). They are not interchangeable and
# never will be - but the record they produce must be the same record, and until
# now nothing checked that. They had already drifted on expoSdk/reactNative.
#
# The schema is written out here rather than diffed between the two files, so a
# failure names the key that moved. Adding a key is a deliberate edit of this
# list plus both scripts; renaming one breaks every reader of the record.
SCHEMA_KEYS='sha version buildNumber stage fingerprint expoSdk reactNative workflowRunId artifacts'

# The object keys of the JSON literal in a build-info.sh, in source order. Both
# scripts build the record as one object literal indented by two spaces inside a
# node program, so the nested fingerprint members do not appear here.
schema_keys_of() {
  grep -oE '^  [A-Za-z][A-Za-z0-9]*:' "$1" | tr -d ' :' | tr '\n' ' ' | sed 's/ $//'
}

@test "this copy emits exactly the documented schema" {
  mine="$(schema_keys_of "$REPO_ROOT/scripts/release/build-info.sh")"
  [ "$mine" = "$SCHEMA_KEYS" ] || fail "this copy's keys drifted from the schema:
--- found    ---
$mine
--- expected ---
$SCHEMA_KEYS"
}

