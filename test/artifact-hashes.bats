#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_OUTPUT_DIR="$BATS_TEST_TMPDIR/out" WORKFLOWS_RELEASE_META_DIR="$BATS_TEST_TMPDIR/meta"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/env" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh_out"
  mkdir -p "$RUNNER_TEMP" "$WORKFLOWS_OUTPUT_DIR" "$WORKFLOWS_RELEASE_META_DIR"
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"
  printf '{"sha":"abc","version":"1.2.3","artifacts":{}}\n' > "$WORKFLOWS_RELEASE_META_DIR/build-info.json"
  unset BUILD_INFO_FILE
}

hashes() { run bash "$REPO_ROOT/scripts/release/artifact-hashes.sh"; }
field() { node -e 'const i=require(process.argv[1]);const p=process.argv[2].split(".");let v=i;for(const k of p)v=v?.[k];console.log(v===undefined?"undefined":String(v))' "$WORKFLOWS_OUTPUT_DIR/build-info.json" "$1"; }

@test "records the apk and aab digests in a copy beside the binaries" {
  printf 'apk bytes\n' > "$WORKFLOWS_OUTPUT_DIR/app.apk"
  printf 'aab bytes\n' > "$WORKFLOWS_OUTPUT_DIR/app.aab"
  hashes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  apk="$(shasum -a 256 "$WORKFLOWS_OUTPUT_DIR/app.apk" | cut -d' ' -f1)"
  aab="$(shasum -a 256 "$WORKFLOWS_OUTPUT_DIR/app.aab" | cut -d' ' -f1)"
  [ "$(field artifacts.apkSha256)" = "$apk" ] || fail "wrong apkSha256: $(cat "$WORKFLOWS_OUTPUT_DIR/build-info.json")"
  [ "$(field artifacts.aabSha256)" = "$aab" ] || fail "wrong aabSha256: $(cat "$WORKFLOWS_OUTPUT_DIR/build-info.json")"
  # The rest of the record survives - this is a merge, not a new file.
  [ "$(field version)" = "1.2.3" ] || fail "the source build-info was not carried over"
  [ "$(field sha)" = "abc" ] || fail "the source build-info was not carried over"
  # The original stays untouched: both platform jobs download the same
  # build-info artifact and must not race to rewrite it.
  ! grep -q apkSha256 "$WORKFLOWS_RELEASE_META_DIR/build-info.json" \
    || fail "the build-info copy was edited in place"
  # The uploaded name is platform-specific, so it cannot collide with
  # build-info's build-info.json inside a merge-multiple download.
  [ -f "$WORKFLOWS_OUTPUT_DIR/build-info.android.json" ] || fail "no per-platform copy was written"
  [ "$(cat "$WORKFLOWS_OUTPUT_DIR/build-info.android.json")" = "$(cat "$WORKFLOWS_OUTPUT_DIR/build-info.json")" ] \
    || fail "the per-platform copy differs from the one verify reads"
}

@test "publishes the enriched path and the digests for later steps" {
  printf 'apk bytes\n' > "$WORKFLOWS_OUTPUT_DIR/app.apk"
  hashes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "BUILD_INFO_FILE=$WORKFLOWS_OUTPUT_DIR/build-info.json" "$GITHUB_ENV" \
    || fail "verify was not pointed at the enriched copy: $(cat "$GITHUB_ENV")"
  apk="$(shasum -a 256 "$WORKFLOWS_OUTPUT_DIR/app.apk" | cut -d' ' -f1)"
  grep -qx "apk-sha256=$apk" "$GITHUB_OUTPUT" || fail "no apk-sha256 output: $(cat "$GITHUB_OUTPUT")"
}

@test "a missing binary is recorded as absent rather than as a wrong digest" {
  printf 'aab bytes\n' > "$WORKFLOWS_OUTPUT_DIR/app.aab"
  hashes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field artifacts.apkSha256)" = "undefined" ] || fail "invented an apk digest: $(cat "$WORKFLOWS_OUTPUT_DIR/build-info.json")"
  [ "$(field artifacts.aabSha256)" != "undefined" ] || fail "the aab digest is missing"
  contains "$output" "no .apk" || fail "the missing apk was not called out: $output"
}

# "The apk" has to be unambiguous for a digest to mean anything.
@test "more than one apk is fatal" {
  printf 'a\n' > "$WORKFLOWS_OUTPUT_DIR/one.apk"
  printf 'b\n' > "$WORKFLOWS_OUTPUT_DIR/two.apk"
  hashes
  [ "$status" -ne 0 ] || fail "picked one of two apks: $output"
  contains "$output" "more than one file matches" || fail "unexpected message: $output"
}

@test "a missing build-info.json is fatal, and names the step that writes it" {
  rm "$WORKFLOWS_RELEASE_META_DIR/build-info.json"
  printf 'apk\n' > "$WORKFLOWS_OUTPUT_DIR/app.apk"
  hashes
  [ "$status" -ne 0 ] || fail "wrote a build-info out of nothing: $output"
  contains "$output" "build-info.sh" || fail "unexpected message: $output"
}

@test "BUILD_INFO_FILE overrides where the source record is read from" {
  printf '{"sha":"other","artifacts":{"keep":"me"}}\n' > "$BATS_TEST_TMPDIR/other.json"
  printf 'apk\n' > "$WORKFLOWS_OUTPUT_DIR/app.apk"
  BUILD_INFO_FILE="$BATS_TEST_TMPDIR/other.json" hashes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(field sha)" = "other" ] || fail "read the wrong source: $(cat "$WORKFLOWS_OUTPUT_DIR/build-info.json")"
  # An existing artifacts entry is merged, not replaced.
  [ "$(field artifacts.keep)" = "me" ] || fail "an existing artifacts entry was dropped"
}
