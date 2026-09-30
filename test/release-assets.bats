#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# `gh` is stubbed with a script that records its argv and serves a release body
# out of a file, so all four modes are exercised - including the re-run of
# `append`, which is the only mode with a re-run story to get wrong.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  ASSETS="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$STUB" "$ASSETS"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/gh.log"
  export WORKFLOWS_TEST_BODY="$BATS_TEST_TMPDIR/body.md"
  export WORKFLOWS_TEST_EXISTS="$BATS_TEST_TMPDIR/exists"
  export WORKFLOWS_TEST_SOURCE_EXISTS="$BATS_TEST_TMPDIR/source-exists"
  export WORKFLOWS_TEST_SOURCE_TAG="v1.2.3-build.42"
  export WORKFLOWS_TEST_SOURCE_ASSETS="$BATS_TEST_TMPDIR/source-assets"
  # Touched by a test to make every `gh release view` fail the way a 403, a 429
  # or a dropped connection does: non-zero, but not a 404.
  export WORKFLOWS_TEST_LOOKUP_FAILS="$BATS_TEST_TMPDIR/lookup-fails"
  # Touched by a test to say the tag was reserved in Prepare.
  export WORKFLOWS_TEST_TAG_EXISTS="$BATS_TEST_TMPDIR/tag-exists"
  export GH_REPO=acme/app
  mkdir -p "$WORKFLOWS_TEST_SOURCE_ASSETS"
  : > "$WORKFLOWS_TEST_LOG"
  printf 'Initial release notes.\n' > "$WORKFLOWS_TEST_BODY"
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
case "$1 $2" in
  "release view")
    case "$*" in
      *"--json url"*) printf 'https://example.test/releases/%s\n' "$3"; exit 0 ;;
      *"--json body"*) cat "$WORKFLOWS_TEST_BODY"; exit 0 ;;
    esac
    # gh's real wording for a missing release, on stderr. The script matches the
    # message, not the status, because `gh release view` exits 1 for a 404, a
    # 403, a 429 and a dropped connection alike - and only the 404 is an answer.
    if [ -f "$WORKFLOWS_TEST_LOOKUP_FAILS" ]; then
      echo "error connecting to api.github.com (HTTP 403)" >&2
      exit 1
    fi
    if [ "$3" = "$WORKFLOWS_TEST_SOURCE_TAG" ]; then
      [ -f "$WORKFLOWS_TEST_SOURCE_EXISTS" ] || { echo "release not found" >&2; exit 1; }
      exit 0
    fi
    [ -f "$WORKFLOWS_TEST_EXISTS" ] || { echo "release not found" >&2; exit 1; }
    exit 0
    ;;
  "release create") : > "$WORKFLOWS_TEST_EXISTS"; exit 0 ;;
  "api "*)
    # `gh api repos/<r>/git/ref/tags/<tag>`: the tag exists when the marker does.
    case "$*" in
      *"/git/ref/tags/"*) [ -f "$WORKFLOWS_TEST_TAG_EXISTS" ] && exit 0; echo "Not Found" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  "release download")
    # Serves the source pre-release's assets out of $WORKFLOWS_TEST_SOURCE_ASSETS.
    [ -f "$WORKFLOWS_TEST_SOURCE_EXISTS" ] || exit 1
    dir=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--dir" ] && dir="$a"
      prev="$a"
    done
    [ -n "$dir" ] || exit 1
    cp "$WORKFLOWS_TEST_SOURCE_ASSETS"/* "$dir"/ 2>/dev/null
    exit 0
    ;;
  "release delete") rm -f "$WORKFLOWS_TEST_SOURCE_EXISTS"; exit 0 ;;
  "release edit")
    # Mirror --notes-file into the stored body, so a second `append` sees the
    # body the first one wrote - which is the whole point of the re-run test.
    prev=""
    for a in "$@"; do
      [ "$prev" = "--notes-file" ] && cp "$a" "$WORKFLOWS_TEST_BODY"
      prev="$a"
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH"
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" WORKFLOWS_ASSETS_DIR="$ASSETS" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_OUTPUT TITLE TARGET_SHA NOTES_FILE APPEND_TITLE FROM_TAG DELETE_SOURCE
}

source_release() {
  : > "$WORKFLOWS_TEST_SOURCE_EXISTS"
  printf 'built ipa\n' > "$WORKFLOWS_TEST_SOURCE_ASSETS/app.ipa"
  printf 'built aab\n' > "$WORKFLOWS_TEST_SOURCE_ASSETS/app.aab"
  printf 'stale sums\n' > "$WORKFLOWS_TEST_SOURCE_ASSETS/SHA256SUMS"
}

assets() {
  printf 'info\n' > "$ASSETS/build-info.json"
  printf 'ipa\n' > "$ASSETS/app.ipa"
  printf 'noise\n' > "$ASSETS/unrelated.txt"
}

release() { run bash "$REPO_ROOT/scripts/release/release-assets.sh" "$@"; }

@test "create-prerelease creates the release and uploads only the fixed asset set" {
  assets
  TAG=v1.2.3 TITLE='Release 1.2.3' TARGET_SHA=deadbeef release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q -- "release create v1.2.3 --prerelease .*--title Release 1.2.3.*--target deadbeef" "$WORKFLOWS_TEST_LOG" \
    || fail "unexpected create argv: $(cat "$WORKFLOWS_TEST_LOG")"
  upload="$(grep '^release upload' "$WORKFLOWS_TEST_LOG")"
  contains "$upload" "build-info.json" || fail "build-info.json was not uploaded: $upload"
  contains "$upload" "app.ipa" || fail "app.ipa was not uploaded: $upload"
  contains "$upload" "SHA256SUMS" || fail "SHA256SUMS was not uploaded: $upload"
  not_contains "$upload" "unrelated.txt" || fail "a file outside the fixed set was uploaded: $upload"
  contains "$upload" "--clobber" || fail "upload is not idempotent (no --clobber): $upload"
}

@test "create-prerelease on a tag reserved in Prepare passes no --target" {
  assets
  : > "$WORKFLOWS_TEST_TAG_EXISTS"
  TAG=v1.2.3 TITLE='Release 1.2.3' TARGET_SHA=deadbeef release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q -- "release create v1.2.3 --prerelease" "$WORKFLOWS_TEST_LOG" || fail "no create: $(cat "$WORKFLOWS_TEST_LOG")"
  ! grep -q -- "--target" "$WORKFLOWS_TEST_LOG" || fail "--target passed for an existing tag, which would try to create it again: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "already exists - creating the release on it" || fail "did not say why: $output"
}

@test "SHA256SUMS lists basenames and real digests" {
  assets
  TAG=v1.2.3 release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -f "$ASSETS/SHA256SUMS" ] || fail "no SHA256SUMS was written"
  grep -q ' build-info.json$' "$ASSETS/SHA256SUMS" || fail "no basename entry: $(cat "$ASSETS/SHA256SUMS")"
  ! grep -q '/' "$ASSETS/SHA256SUMS" || fail "SHA256SUMS contains a path, not just basenames"
  expected="$(cd "$ASSETS" && shasum -a 256 app.ipa | cut -d' ' -f1)"
  grep -q "^$expected  app.ipa$" "$ASSETS/SHA256SUMS" || fail "wrong digest for app.ipa"
}

@test "promote leaves the release out of latest, latest marks it" {
  : > "$WORKFLOWS_TEST_EXISTS"
  # Both modes now refuse to publish an empty release, and this case is about
  # the --latest flags, so give it something to publish.
  printf 'ipa\n' > "$ASSETS/app.ipa"
  TAG=v1.2.3 release promote
  [ "$status" -eq 0 ] || fail "promote exited $status: $output"
  grep -q -- "release edit v1.2.3 --prerelease=false --latest=false" "$WORKFLOWS_TEST_LOG" \
    || fail "unexpected promote argv: $(cat "$WORKFLOWS_TEST_LOG")"
  : > "$WORKFLOWS_TEST_LOG"
  TAG=v1.2.3 release latest
  [ "$status" -eq 0 ] || fail "latest exited $status: $output"
  grep -q -- "release edit v1.2.3 --prerelease=false --latest$" "$WORKFLOWS_TEST_LOG" \
    || fail "unexpected latest argv: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "promote on a release that does not exist is fatal" {
  rm -f "$WORKFLOWS_TEST_EXISTS"
  TAG=v9.9.9 release promote
  [ "$status" -ne 0 ] || fail "promoted a release that does not exist: $output"
  contains "$output" "does not exist" || fail "unexpected message: $output"
}

@test "promote carries the source pre-release's assets forward and regenerates SHA256SUMS" {
  : > "$WORKFLOWS_TEST_EXISTS"
  source_release
  printf 'info\n' > "$ASSETS/build-info.json"
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" release promote
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q "^release download $WORKFLOWS_TEST_SOURCE_TAG .*--clobber" "$WORKFLOWS_TEST_LOG" \
    || fail "the source assets were not downloaded: $(cat "$WORKFLOWS_TEST_LOG")"
  upload="$(grep '^release upload v1.2.3' "$WORKFLOWS_TEST_LOG")"
  contains "$upload" "app.ipa" || fail "the carried-forward ipa was not uploaded: $upload"
  contains "$upload" "app.aab" || fail "the carried-forward aab was not uploaded: $upload"
  contains "$upload" "build-info.json" || fail "this run's own asset was dropped: $upload"
  contains "$upload" "--clobber" || fail "the promote upload is not idempotent: $upload"
  # The source's own SHA256SUMS came down with the rest; it must be recomputed
  # over the merged set, not shipped as-is.
  not_contains "$(cat "$ASSETS/SHA256SUMS")" "stale sums" \
    || fail "the source SHA256SUMS was published verbatim: $(cat "$ASSETS/SHA256SUMS")"
  expected="$(cd "$ASSETS" && shasum -a 256 app.ipa | cut -d' ' -f1)"
  grep -q "^$expected  app.ipa$" "$ASSETS/SHA256SUMS" || fail "wrong digest for the carried ipa"
}

# N1: the download used to land in $WORKFLOWS_ASSETS_DIR with --clobber, so the source
# pre-release's build-info.json and notes (an *earlier* stage's) replaced this
# run's - on the release record and in the OTA gate's baseline.
@test "this run's release-meta wins over the source pre-release's copy" {
  : > "$WORKFLOWS_TEST_EXISTS"
  source_release
  printf 'this-run\n' > "$ASSETS/build-info.json"
  printf 'this-run notes\n' > "$ASSETS/notes.md"
  printf 'source\n' > "$WORKFLOWS_TEST_SOURCE_ASSETS/build-info.json"
  printf 'source notes\n' > "$WORKFLOWS_TEST_SOURCE_ASSETS/notes.md"
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" release promote
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$ASSETS/build-info.json")" = "this-run" ] \
    || fail "the source build-info.json overwrote this run's: $(cat "$ASSETS/build-info.json")"
  [ "$(cat "$ASSETS/notes.md")" = "this-run notes" ] \
    || fail "the source notes overwrote this run's: $(cat "$ASSETS/notes.md")"
  # The binaries this run does not have still come across.
  upload="$(grep '^release upload v1.2.3' "$WORKFLOWS_TEST_LOG")"
  contains "$upload" "app.aab" || fail "the carried-forward aab was dropped: $upload"
}

# N2: with no carried asset, promote used to take the release out of pre-release
# with nothing attached and then (with delete-source) delete the tested bytes.
@test "promote refuses a from-tag release that carries no assets" {
  : > "$WORKFLOWS_TEST_EXISTS"
  : > "$WORKFLOWS_TEST_SOURCE_EXISTS"
  rm -f "$WORKFLOWS_TEST_SOURCE_ASSETS"/*
  printf 'this-run\n' > "$ASSETS/build-info.json"
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" DELETE_SOURCE=true release promote
  [ "$status" -ne 0 ] || fail "promoted an empty source release: $output"
  contains "$output" "refusing to promote an empty release" || fail "unexpected message: $output"
  ! grep -q '^release delete' "$WORKFLOWS_TEST_LOG" || fail "deleted the source anyway: $(cat "$WORKFLOWS_TEST_LOG")"
  ! grep -q '^release upload' "$WORKFLOWS_TEST_LOG" || fail "uploaded before the check: $(cat "$WORKFLOWS_TEST_LOG")"
  ! grep -q -- '--prerelease=false' "$WORKFLOWS_TEST_LOG" || fail "took the release out of pre-release anyway"
  [ -f "$WORKFLOWS_TEST_SOURCE_EXISTS" ] || fail "the source pre-release is gone"
}

@test "promote does not delete the source unless asked" {
  : > "$WORKFLOWS_TEST_EXISTS"
  source_release
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" release promote
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  ! grep -q '^release delete' "$WORKFLOWS_TEST_LOG" || fail "deleted the source without delete-source"
  [ -f "$WORKFLOWS_TEST_SOURCE_EXISTS" ] || fail "the source pre-release is gone"
}

@test "promote with delete-source removes the pre-release and its tag, after the upload" {
  : > "$WORKFLOWS_TEST_EXISTS"
  source_release
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" DELETE_SOURCE=true release promote
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q "^release delete $WORKFLOWS_TEST_SOURCE_TAG --yes --cleanup-tag$" "$WORKFLOWS_TEST_LOG" \
    || fail "the source was not deleted with its tag: $(cat "$WORKFLOWS_TEST_LOG")"
  # Ordering is the safety property: deleting first would leave no copy of the
  # binaries anywhere if the upload then failed.
  upload_line="$(grep -n '^release upload' "$WORKFLOWS_TEST_LOG" | head -1 | cut -d: -f1)"
  delete_line="$(grep -n '^release delete' "$WORKFLOWS_TEST_LOG" | head -1 | cut -d: -f1)"
  [ "$upload_line" -lt "$delete_line" ] || fail "the source was deleted before the upload"
}

@test "re-running a promote whose source is already deleted still succeeds" {
  : > "$WORKFLOWS_TEST_EXISTS"
  source_release
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" DELETE_SOURCE=true release promote
  [ "$status" -eq 0 ] || fail "first promote exited $status: $output"
  first_upload="$(grep '^release upload v1.2.3' "$WORKFLOWS_TEST_LOG")"
  : > "$WORKFLOWS_TEST_LOG"
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" DELETE_SOURCE=true release promote
  [ "$status" -eq 0 ] || fail "re-run exited $status: $output"
  contains "$output" "already promoted and deleted" || fail "unexpected message on re-run: $output"
  [ "$first_upload" = "$(grep '^release upload v1.2.3' "$WORKFLOWS_TEST_LOG")" ] \
    || fail "the re-run uploaded a different asset set"
}

@test "append adds the section under its heading" {
  : > "$WORKFLOWS_TEST_EXISTS"
  printf -- '- rolled out to 10%%\n' > "$BATS_TEST_TMPDIR/section.md"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "Initial release notes." || fail "the existing body was dropped"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "## Store rollout" || fail "no heading in: $(cat "$WORKFLOWS_TEST_BODY")"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "rolled out to 10%" || fail "no section body in: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "append is idempotent - a re-run yields a byte-identical body" {
  : > "$WORKFLOWS_TEST_EXISTS"
  printf -- '- rolled out to 10%%\n' > "$BATS_TEST_TMPDIR/section.md"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "first append exited $status: $output"
  first="$(cat "$WORKFLOWS_TEST_BODY")"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "second append exited $status: $output"
  second="$(cat "$WORKFLOWS_TEST_BODY")"
  [ "$first" = "$second" ] || fail "re-running append changed the body:
--- first ---
$first
--- second ---
$second"
  [ "$(grep -c '^## Store rollout$' "$WORKFLOWS_TEST_BODY")" -eq 1 ] \
    || fail "the section is duplicated: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "a re-run with different content replaces the section rather than stacking it" {
  : > "$WORKFLOWS_TEST_EXISTS"
  printf -- '- rolled out to 10%%\n' > "$BATS_TEST_TMPDIR/section.md"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "first append exited $status: $output"
  printf -- '- rolled out to 100%%\n' > "$BATS_TEST_TMPDIR/section.md"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "second append exited $status: $output"
  body="$(cat "$WORKFLOWS_TEST_BODY")"
  contains "$body" "rolled out to 100%" || fail "the new content is missing: $body"
  not_contains "$body" "rolled out to 10%\n" || fail "the stale content survived: $body"
  [ "$(grep -c '^## Store rollout$' "$WORKFLOWS_TEST_BODY")" -eq 1 ] || fail "the section is duplicated: $body"
}

# The regression U1 was: the strip ran from the heading to the next `## `, so a
# notes file that itself starts with a heading terminated the strip early and its
# tail stacked on every re-run. That was the *default* shape - notes.sh's old
# commit-subject fallback wrote `## <version> (<build>)` - and a release-please
# body still starts with `## [x.y.z](...)`.
@test "append is idempotent when the notes file itself starts with a ## heading" {
  : > "$WORKFLOWS_TEST_EXISTS"
  cat > "$BATS_TEST_TMPDIR/section.md" <<'EOF'
## [1.2.3](https://example.test/compare/v1.2.2...v1.2.3) (2026-09-06)

### Features

- a feature

### Bug Fixes

- a fix
EOF
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Release notes' release append
  [ "$status" -eq 0 ] || fail "first append exited $status: $output"
  first="$(cat "$WORKFLOWS_TEST_BODY")"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Release notes' release append
  [ "$status" -eq 0 ] || fail "second append exited $status: $output"
  second="$(cat "$WORKFLOWS_TEST_BODY")"
  [ "$first" = "$second" ] || fail "re-running append changed the body:
--- first ($(printf '%s' "$first" | wc -l | tr -d ' ') lines) ---
$first
--- second ($(printf '%s' "$second" | wc -l | tr -d ' ') lines) ---
$second"
  [ "$(grep -c '^- a feature$' "$WORKFLOWS_TEST_BODY")" -eq 1 ] \
    || fail "the notes body is duplicated: $(cat "$WORKFLOWS_TEST_BODY")"
  [ "$(grep -c '^### Bug Fixes$' "$WORKFLOWS_TEST_BODY")" -eq 1 ] \
    || fail "a subsection survived the strip: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "append migrates a body written before the markers existed, without stacking" {
  : > "$WORKFLOWS_TEST_EXISTS"
  # Exactly what the pre-marker version of this script produced.
  cat > "$WORKFLOWS_TEST_BODY" <<'EOF'
Initial release notes.

## Store rollout

- rolled out to 10%
EOF
  printf -- '- rolled out to 100%%\n' > "$BATS_TEST_TMPDIR/section.md"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "migration append exited $status: $output"
  [ "$(grep -c '^## Store rollout$' "$WORKFLOWS_TEST_BODY")" -eq 1 ] \
    || fail "the legacy section was not replaced: $(cat "$WORKFLOWS_TEST_BODY")"
  not_contains "$(cat "$WORKFLOWS_TEST_BODY")" "rolled out to 10%
" || fail "the legacy content survived: $(cat "$WORKFLOWS_TEST_BODY")"
  grep -qxF '<!-- workflows:append:Store rollout -->' "$WORKFLOWS_TEST_BODY" \
    || fail "the migrated body carries no marker: $(cat "$WORKFLOWS_TEST_BODY")"
  first="$(cat "$WORKFLOWS_TEST_BODY")"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "second append exited $status: $output"
  [ "$first" = "$(cat "$WORKFLOWS_TEST_BODY")" ] || fail "the run after migration was not idempotent"
}

# append runs after a store action, from a job with no binaries staged: an
# upload there attaches nothing and regenerates SHA256SUMS over an empty or
# partial directory, replacing the checksum file that describes the release's
# real assets.
@test "append touches the body and nothing else" {
  : > "$WORKFLOWS_TEST_EXISTS"
  assets
  printf 'real sums\n' > "$ASSETS/SHA256SUMS"
  printf -- '- rolled out to 10%%\n' > "$BATS_TEST_TMPDIR/section.md"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" APPEND_TITLE='Store rollout' release append
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  ! grep -q '^release upload' "$WORKFLOWS_TEST_LOG" || fail "append uploaded assets: $(cat "$WORKFLOWS_TEST_LOG")"
  [ "$(cat "$ASSETS/SHA256SUMS")" = "real sums" ] \
    || fail "append regenerated SHA256SUMS: $(cat "$ASSETS/SHA256SUMS")"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "rolled out to 10%" || fail "the body was not updated"
}

@test "append takes its section from NOTES_TEXT when there is no notes file" {
  : > "$WORKFLOWS_TEST_EXISTS"
  TAG=v1.2.3 NOTES_TEXT='release at 25%, platforms all' APPEND_TITLE='Production' RUNNER_TEMP="$BATS_TEST_TMPDIR" release append
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "## Production" || fail "no heading in: $(cat "$WORKFLOWS_TEST_BODY")"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "release at 25%, platforms all" || fail "no text in: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "NOTES_TEXT wins over a notes file" {
  : > "$WORKFLOWS_TEST_EXISTS"
  printf 'from the file\n' > "$BATS_TEST_TMPDIR/section.md"
  TAG=v1.2.3 NOTES_FILE="$BATS_TEST_TMPDIR/section.md" NOTES_TEXT='from the text' APPEND_TITLE='Production' \
    RUNNER_TEMP="$BATS_TEST_TMPDIR" release append
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "from the text" || fail "the text was not used: $(cat "$WORKFLOWS_TEST_BODY")"
  not_contains "$(cat "$WORKFLOWS_TEST_BODY")" "from the file" || fail "the file was used over the text: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "a release created with NOTES_TEXT gets it as its notes, not generated ones" {
  TAG=v1.2.3 TARGET_SHA=deadbeef NOTES_TEXT='hand-written notes' RUNNER_TEMP="$BATS_TEST_TMPDIR" release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  create="$(grep '^release create' "$WORKFLOWS_TEST_LOG")"
  contains "$create" "--notes-file $BATS_TEST_TMPDIR/workflows-release-notes-text.md" || fail "the text was not the notes: $create"
  not_contains "$create" "--generate-notes" || fail "notes were generated despite the text: $create"
  [ "$(cat "$BATS_TEST_TMPDIR/workflows-release-notes-text.md")" = "hand-written notes" ] || fail "the notes file holds the wrong text"
}

@test "append without a notes file is fatal" {
  : > "$WORKFLOWS_TEST_EXISTS"
  TAG=v1.2.3 release append
  [ "$status" -ne 0 ] || fail "appended nothing successfully: $output"
  contains "$output" "NOTES_FILE" || fail "unexpected message: $output"
}

@test "an unknown mode is fatal" {
  TAG=v1.2.3 release publish-everything
  [ "$status" -ne 0 ] || fail "accepted an unknown mode: $output"
  contains "$output" "unknown mode" || fail "unexpected message: $output"
}

@test "no assets is not an error while the release is still a pre-release" {
  # create-prerelease legitimately runs before a platform has finished building;
  # the binaries arrive on a later re-run, which uploads with --clobber.
  TAG=v1.2.3 release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status with an empty assets dir: $output"
  contains "$output" "no release assets found" || fail "unexpected message: $output"
  ! grep -q '^release upload' "$WORKFLOWS_TEST_LOG" || fail "uploaded with nothing to upload"
}

@test "publishing an empty release is fatal, not a shrug" {
  # `latest` and `promote` take a release out of pre-release. Doing that with no
  # binaries attached publishes an empty release to users - and under promote's
  # DELETE_SOURCE the tested bytes are deleted right after. A guard for this
  # existed but sat inside the carry-forward branch, so every path that skipped
  # that branch walked straight past it.
  : > "$WORKFLOWS_TEST_EXISTS"
  TAG=v1.2.3 release latest
  [ "$status" -ne 0 ] || fail "published an empty release: $output"
  contains "$output" "refusing to publish" || fail "unexpected message: $output"
  ! grep -q '^release upload' "$WORKFLOWS_TEST_LOG" || fail "uploaded anyway"
}

@test "promoting an empty release is fatal even with no FROM_TAG at all" {
  : > "$WORKFLOWS_TEST_EXISTS"
  TAG=v1.2.3 release promote
  [ "$status" -ne 0 ] || fail "promoted an empty release: $output"
  contains "$output" "refusing to publish" || fail "unexpected message: $output"
}

# --- a failed lookup is not evidence of absence ------------------------------
#
# `gh release view >/dev/null 2>&1` exits 1 for a 404, a 403, a 429 and a
# dropped connection alike. Reading all of those as "the release is gone" is
# what let a blip take the "already promoted and deleted?" branch, skip the
# empty-release guard that lived inside the other branch, and publish.

@test "a failed FROM_TAG lookup stops the promote instead of guessing" {
  : > "$WORKFLOWS_TEST_EXISTS"
  : > "$WORKFLOWS_TEST_SOURCE_EXISTS"
  cp "$WORKFLOWS_TEST_BODY" "$WORKFLOWS_TEST_SOURCE_ASSETS/notes.md"
  : > "$WORKFLOWS_TEST_LOOKUP_FAILS"
  TAG=v1.2.3 FROM_TAG="$WORKFLOWS_TEST_SOURCE_TAG" release promote
  [ "$status" -ne 0 ] || fail "a 403 was read as 'the source is gone': $output"
  contains "$output" "refusing" || fail "unexpected message: $output"
  ! grep -q '^release edit' "$WORKFLOWS_TEST_LOG" || fail "took the release out of pre-release on a guess"
}

@test "a failed lookup of the target release stops every mode" {
  : > "$WORKFLOWS_TEST_LOOKUP_FAILS"
  for mode in create-prerelease promote latest append; do
    TAG=v1.2.3 release "$mode"
    [ "$status" -ne 0 ] || fail "$mode continued after a failed lookup: $output"
  done
}

@test "a genuine 404 is still read as absent" {
  # The fix must not turn "not found" into an error: create-prerelease depends
  # on telling those apart, and so does the promote re-run path.
  TAG=v1.2.3 release create-prerelease
  [ "$status" -eq 0 ] || fail "a missing release was treated as a lookup failure: $output"
  grep -q '^release create' "$WORKFLOWS_TEST_LOG" || fail "it did not create the release: $(cat "$WORKFLOWS_TEST_LOG")"
}

# --- a release can say something about itself -------------------------------
#
# $BODY_NOTE puts a Markdown note admonition at the top of the body at creation
# time. It exists so a release can carry a fact its notes cannot know - today,
# that store uploads were switched off and this build never reached a store.
#
# At creation rather than through a follow-up `append`: an appended marker
# leaves a window in which the release reads as an ordinary store build.

body_of() { sed -n 's/^release create [^ ]* //p' "$WORKFLOWS_TEST_LOG"; }

@test "a body note is written to the notes file the release is created from" {
  printf 'ipa\n' > "$ASSETS/app.ipa"
  TAG=v1.2.3 BODY_NOTE='Store uploads were off for this build.' release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  note="$RUNNER_TEMP/workflows-release-note.md"
  # The script cleans up on exit, so the assertion is on what gh was handed.
  grep -q -- '--notes-file' "$WORKFLOWS_TEST_LOG" || fail "no notes file was passed: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -q -- 'workflows-release-note.md' "$WORKFLOWS_TEST_LOG" \
    || fail "gh was not handed the note file: $(cat "$WORKFLOWS_TEST_LOG")"
  [ ! -f "$note" ] || fail "the scratch note survived the run"
}

@test "with no notes of its own, the note is prepended to generated notes" {
  # gh prepends supplied notes to the ones it generates, so the two combine
  # rather than conflict - the note lands above real release notes.
  printf 'ipa\n' > "$ASSETS/app.ipa"
  TAG=v1.2.3 BODY_NOTE='No store upload.' release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q -- '--generate-notes' "$WORKFLOWS_TEST_LOG" \
    || fail "a body note suppressed generated notes: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a supplied notes file keeps its content, with the note above it" {
  printf 'ipa\n' > "$ASSETS/app.ipa"
  printf 'The real release notes.\n' > "$ASSETS/notes.md"
  TAG=v1.2.3 NOTES_FILE="$ASSETS/notes.md" BODY_NOTE='No store upload.' \
 release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  # Supplied notes are not generated ones, so gh must not be asked to generate.
  ! grep -q -- '--generate-notes' "$WORKFLOWS_TEST_LOG" \
    || fail "asked gh to generate notes over a supplied file: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "no body note leaves the notes arguments exactly as they were" {
  printf 'ipa\n' > "$ASSETS/app.ipa"
  printf 'The real release notes.\n' > "$ASSETS/notes.md"
  TAG=v1.2.3 NOTES_FILE="$ASSETS/notes.md" release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q -- "--notes-file $ASSETS/notes.md" "$WORKFLOWS_TEST_LOG" \
    || fail "the supplied notes file was not used verbatim: $(cat "$WORKFLOWS_TEST_LOG")"
  ! grep -q -- 'workflows-release-note.md' "$WORKFLOWS_TEST_LOG" \
    || fail "a note file appeared without a body note"
}

@test "every mode that creates or promotes a release accepts a body note" {
  # `latest` publishes to users just as `create-prerelease` does, so it must be
  # able to carry the same marker.
  printf 'ipa\n' > "$ASSETS/app.ipa"
  : > "$WORKFLOWS_TEST_EXISTS"
  TAG=v1.2.3 BODY_NOTE='No store upload.' release latest
  [ "$status" -eq 0 ] || fail "latest exited $status: $output"
}

@test "a body note also reaches the run summary" {
  # The release body is the durable record; the run summary is what someone
  # reading a green run sees without opening the release.
  printf 'ipa\n' > "$ASSETS/app.ipa"
  summary="$BATS_TEST_TMPDIR/summary.md"
  : > "$summary"
  TAG=v1.2.3 BODY_NOTE='Store uploads were off.' GITHUB_STEP_SUMMARY="$summary" \
    release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q 'Store uploads were off.' "$summary" || fail "the note is not in the summary: $(cat "$summary")"
  grep -q 'v1.2.3' "$summary" || fail "the summary does not name the tag: $(cat "$summary")"
}

@test "no body note writes nothing to the run summary" {
  printf 'ipa\n' > "$ASSETS/app.ipa"
  summary="$BATS_TEST_TMPDIR/summary.md"
  : > "$summary"
  TAG=v1.2.3 GITHUB_STEP_SUMMARY="$summary" release create-prerelease
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$summary" ] || fail "wrote a summary for an unmarked release: $(cat "$summary")"
}
