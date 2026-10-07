#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# A fake `gh release download`: writes FAKE_ASSETS (space-separated names) into
# --dir, or fails with FAKE_DOWNLOAD_ERROR the way gh does. Every call is logged.
setup() {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$1 $2" = "release download" ] || { echo "unexpected gh invocation: $*" >&2; exit 2; }
if [ -n "${FAKE_DOWNLOAD_ERROR:-}" ]; then echo "$FAKE_DOWNLOAD_ERROR" >&2; exit 1; fi
prev=""; dir=""
for a in "$@"; do [ "$prev" = "--dir" ] && dir="$a"; prev="$a"; done
for name in ${FAKE_ASSETS-app-release.aab}; do printf 'bytes' > "$dir/$name"; done
exit 0
EOF
  chmod +x "$fakebin/gh"
  export PATH="$fakebin:$PATH"
  export GH_TOKEN=fake GH_REPO=org/app
  dir="$BATS_TEST_TMPDIR/assets"
}

fetch() { run bash "$REPO_ROOT/scripts/release/release-assets-fetch.sh" "$@"; }

@test "the matching assets of the tag land in the directory, and are named" {
  fetch v1.2.3 '*.aab' "$dir"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "release download v1.2.3 --pattern \*.aab --dir $dir --clobber" "$GH_LOG" \
    || fail "unexpected gh argv: $(cat "$GH_LOG")"
  [ -s "$dir/app-release.aab" ] || fail "the asset did not land in $dir"
  contains "$output" "release v1.2.3: app-release.aab into $dir" || fail "the download was not reported: $output"
  traced "$output" "Download *.aab from release v1.2.3" || fail "the download was not timed: $output"
}

@test "a directory that does not exist yet is created" {
  FAKE_ASSETS='a.aab b.aab' fetch v1.2.3 '*.aab' "$dir/nested"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -s "$dir/nested/a.aab" ] && [ -s "$dir/nested/b.aab" ] || fail "the assets did not land in the new directory"
  contains "$output" "release v1.2.3: a.aab b.aab into $dir/nested" || fail "unexpected report: $output"
}

@test "only files matching the pattern are reported, not what the artifacts already put there" {
  mkdir -p "$dir" && printf 'meta' > "$dir/build-info.json"
  fetch v1.2.3 '*.aab' "$dir"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -s "$dir/build-info.json" ] || fail "the file already in the directory was removed"
  not_contains "$output" "build-info.json" || fail "a file the release did not match was reported: $output"
}

@test "no release-tag is fatal, naming the missing input and the fix" {
  fetch '' '*.aab' "$dir"
  [ "$status" -ne 0 ] || fail "ran without a tag: $output"
  contains "$output" "release-assets is *.aab, but no release-tag says which release to take them from" || fail "output: $output"
  contains "$output" "publish-store.yml" || fail "the fix does not name the workflow: $output"
  [ ! -s "$GH_LOG" ] || fail "called gh anyway: $(cat "$GH_LOG")"
}

@test "no matching asset is fatal, with gh's own reason" {
  FAKE_DOWNLOAD_ERROR='no assets match the file pattern' fetch v1.2.3 '*.aab' "$dir"
  [ "$status" -ne 0 ] || fail "a release with no bundle passed: $output"
  contains "$output" "could not download *.aab from release v1.2.3 in org/app: no assets match the file pattern" \
    || fail "output: $output"
}

@test "a missing pattern or directory is fatal, with the usage" {
  fetch v1.2.3
  [ "$status" -ne 0 ] || fail "ran without a pattern: $output"
  contains "$output" "usage: release-assets-fetch.sh TAG PATTERN DIR" || fail "output: $output"
  fetch v1.2.3 '*.aab'
  [ "$status" -ne 0 ] || fail "ran without a directory: $output"
  contains "$output" "usage: release-assets-fetch.sh TAG PATTERN DIR" || fail "output: $output"
}
