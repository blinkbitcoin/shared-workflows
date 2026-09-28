#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/self/package-copies.sh: the release scripts packages/dev-config ships
# must be byte-identical to the ones build-prepare.yml runs, or a consumer's
# laptop resolves a version one way and its release another.
load test_helper

@test "the package's release scripts are the ones the workflows run" {
  run bash "$REPO_ROOT/scripts/self/package-copies.sh"
  [ "$status" -eq 0 ] || fail "stale copies: $output"
  contains "$output" "package copies ok (4 files)" || fail "output: $output"
}

# A tree of its own, so the cases below can change originals and copies freely.
tree() {
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/scripts/self" "$tree/scripts/lib" "$tree/scripts/release"
  cp "$REPO_ROOT/scripts/self/package-copies.sh" "$tree/scripts/self/"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$REPO_ROOT/scripts/lib/release-env.sh" "$tree/scripts/lib/"
  cp "$REPO_ROOT/scripts/release/resolve-version.sh" "$REPO_ROOT/scripts/release/build-info.sh" "$tree/scripts/release/"
}

@test "--write copies every original into the package, and the copies then check clean" {
  tree
  run bash "$tree/scripts/self/package-copies.sh" --write
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "copied 4 files into packages/dev-config" || fail "output: $output"
  for rel in release/resolve-version.sh release/build-info.sh lib/common.sh lib/release-env.sh; do
    cmp -s "$tree/scripts/$rel" "$tree/packages/dev-config/$rel" || fail "packages/dev-config/$rel is not a copy"
  done
  [ -x "$tree/packages/dev-config/release/resolve-version.sh" ] || [ ! -x "$tree/scripts/release/resolve-version.sh" ] \
    || fail "the copy lost the original's executable bit"
  run bash "$tree/scripts/self/package-copies.sh"
  [ "$status" -eq 0 ] || fail "fresh copies did not check clean: $output"
}

@test "a changed original, or a missing copy, fails naming each stale copy and the fix" {
  tree
  bash "$tree/scripts/self/package-copies.sh" --write
  printf '# changed\n' >> "$tree/scripts/release/build-info.sh"
  rm "$tree/packages/dev-config/lib/common.sh"
  run bash "$tree/scripts/self/package-copies.sh"
  [ "$status" -ne 0 ] || fail "stale copies checked clean: $output"
  contains "$output" "packages/dev-config/release/build-info.sh packages/dev-config/lib/common.sh" || fail "output: $output"
  contains "$output" "run: bash scripts/self/package-copies.sh --write" || fail "the fix was not named: $output"
  not_contains "$output" "resolve-version.sh" || fail "a current copy was reported: $output"
}

@test "a missing original is fatal, whether checking or writing" {
  tree
  rm "$tree/scripts/lib/release-env.sh"
  for mode in "" --write; do
    run bash "$tree/scripts/self/package-copies.sh" $mode
    [ "$status" -ne 0 ] || fail "ran '$mode' without an original: $output"
    contains "$output" "no $tree/scripts/lib/release-env.sh to copy into the package" || fail "output: $output"
  done
}

@test "an unknown argument is fatal, with the usage" {
  run bash "$REPO_ROOT/scripts/self/package-copies.sh" --check
  [ "$status" -ne 0 ] || fail "accepted --check: $output"
  contains "$output" "usage: package-copies.sh [--write]" || fail "output: $output"
}
