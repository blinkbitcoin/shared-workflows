#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

SCRIPT="$REPO_ROOT/scripts/self/pack-app-tooling.sh"

# A fake npm: logs its arguments and working directory, writes the tarball into
# --pack-destination and prints FAKE_REPORT (a one-entry report naming it by
# default). FAKE_FAILS makes it fail; FAKE_NO_FILE makes it report a file it
# did not write.
setup() {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  cat > "$bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s | %s\n' "$PWD" "$*" >> "$NPM_LOG"
[ -z "${FAKE_FAILS:-}" ] || { echo "npm error code E401" >&2; exit 1; }
destination=""
while [ "$#" -gt 0 ]; do
  [ "$1" = "--pack-destination" ] && destination="$2"
  shift
done
[ -n "${FAKE_NO_FILE:-}" ] || : > "$destination/blinkbitcoin-app-tooling-1.2.3.tgz"
echo "npm notice a lifecycle line" >&2
report='[{"filename":"blinkbitcoin-app-tooling-1.2.3.tgz"}]'
printf '%s\n' "${FAKE_REPORT:-$report}"
EOF
  as_fakes "$bin/npm"
  export PATH="$bin:$PATH"
  package="$BATS_TEST_TMPDIR/package"
  mkdir -p "$package"
  printf '{"name":"@blinkbitcoin/app-tooling"}\n' > "$package/package.json"
  destination="$BATS_TEST_TMPDIR/out"
}

@test "packs the package into the destination and outputs the tarball's absolute path" {
  run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  real="$(cd "$destination" && pwd -P)"
  contains "$output" "tarball=$real/blinkbitcoin-app-tooling-1.2.3.tgz" || fail "no tarball output: $output"
  [ -f "$real/blinkbitcoin-app-tooling-1.2.3.tgz" ] || fail "the tarball is not in the destination"
  [ "$(cat "$NPM_LOG")" = "$package | pack --json --pack-destination $real" ] \
    || fail "unexpected npm call: $(cat "$NPM_LOG")"
}

@test "writes the tarball to GITHUB_OUTPUT when the runner sets it" {
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output" run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$BATS_TEST_TMPDIR/github-output")" = "tarball=$(cd "$destination" && pwd -P)/blinkbitcoin-app-tooling-1.2.3.tgz" ] \
    || fail "GITHUB_OUTPUT holds: $(cat "$BATS_TEST_TMPDIR/github-output")"
}

@test "fails without exactly two arguments" {
  run bash "$SCRIPT" "$package"
  [ "$status" -ne 0 ] || fail "accepted one argument: $output"
  contains "$output" "usage: pack-app-tooling.sh PACKAGE_DIR DESTINATION_DIR" || fail "no usage: $output"
  [ ! -e "$NPM_LOG" ] || fail "ran npm anyway"
}

@test "fails when the package directory has no package.json" {
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/nowhere" "$destination"
  [ "$status" -ne 0 ] || fail "accepted a directory with no package.json: $output"
  contains "$output" "no package.json in '$BATS_TEST_TMPDIR/nowhere'" || fail "output: $output"
  [ ! -e "$NPM_LOG" ] || fail "ran npm anyway"
}

@test "fails when npm pack fails" {
  FAKE_FAILS=1 run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -ne 0 ] || fail "a failed pack passed: $output"
  contains "$output" "npm pack failed in '$package'" || fail "output: $output"
  not_contains "$output" "tarball=" || fail "output a tarball anyway: $output"
}

@test "fails when npm pack reports something that is not a JSON array" {
  FAKE_REPORT='not json' run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -ne 0 ] || fail "accepted a report that is not JSON: $output"
  contains "$output" "npm pack did not report a JSON array: not json" || fail "output: $output"
  FAKE_REPORT='{"filename":"x.tgz"}' run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -ne 0 ] || fail "accepted an object report: $output"
  contains "$output" "did not report a JSON array" || fail "output: $output"
}

@test "fails when npm pack reports other than one package" {
  FAKE_REPORT='[]' run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -ne 0 ] || fail "accepted an empty report: $output"
  contains "$output" "npm pack reported 0 packages, not one" || fail "output: $output"
  FAKE_REPORT='[{"filename":"a.tgz"},{"filename":"b.tgz"}]' run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -ne 0 ] || fail "accepted two packages: $output"
  contains "$output" "npm pack reported 2 packages, not one" || fail "output: $output"
}

@test "fails when the report names no file" {
  FAKE_REPORT='[{"name":"@blinkbitcoin/app-tooling"}]' run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -ne 0 ] || fail "accepted a report with no file name: $output"
  contains "$output" "npm pack reported no file name" || fail "output: $output"
}

@test "fails when the reported tarball is not in the destination" {
  FAKE_NO_FILE=1 run bash "$SCRIPT" "$package" "$destination"
  [ "$status" -ne 0 ] || fail "accepted a missing tarball: $output"
  contains "$output" "npm pack reported 'blinkbitcoin-app-tooling-1.2.3.tgz', which is not in" || fail "output: $output"
  not_contains "$output" "tarball=" || fail "output a tarball anyway: $output"
}
