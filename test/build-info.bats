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

