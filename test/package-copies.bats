#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/self/package-copies.sh: the scripts packages/dev-config ships must be
# byte-identical to the ones the workflows run, or a consumer's laptop resolves
# a version, or passes a check, one way and CI another.
load test_helper

@test "the package's release scripts are the ones the workflows run" {
  run bash "$REPO_ROOT/scripts/self/package-copies.sh"
  [ "$status" -eq 0 ] || fail "stale copies: $output"
  contains "$output" "package copies ok (15 files)" || fail "output: $output"
}

# A tree of its own, so the cases below can change originals and copies freely.
tree() {
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/scripts/self" "$tree/scripts/lib" "$tree/scripts/release" "$tree/scripts/checks" "$tree/scripts/ci" "$tree/scripts/hooks" "$tree/.github"
  cp "$REPO_ROOT/scripts/self/package-copies.sh" "$tree/scripts/self/"
  cp "$REPO_ROOT"/scripts/lib/{common,release-env,git-clean,versions}.sh "$tree/scripts/lib/"
  cp "$REPO_ROOT/scripts/release/resolve-version.sh" "$REPO_ROOT/scripts/release/build-info.sh" "$tree/scripts/release/"
  cp "$REPO_ROOT"/scripts/checks/{i18n,codegen,secrets,run-script,expo-doctor}.sh "$tree/scripts/checks/"
  cp "$REPO_ROOT"/scripts/ci/{lint-ci,maestro-install}.sh "$tree/scripts/ci/"
  cp "$REPO_ROOT/scripts/hooks/install-if-lockfile-changed.sh" "$tree/scripts/hooks/"
  cp "$REPO_ROOT/.github/zizmor.yml" "$tree/.github/"
}

@test "--write copies every original into the package, and the copies then check clean" {
  tree
  run bash "$tree/scripts/self/package-copies.sh" --write
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "copied 15 files into packages/dev-config" || fail "output: $output"
  for rel in release/resolve-version.sh release/build-info.sh checks/i18n.sh checks/codegen.sh checks/secrets.sh \
    checks/run-script.sh checks/expo-doctor.sh ci/lint-ci.sh ci/maestro-install.sh hooks/install-if-lockfile-changed.sh \
    lib/common.sh lib/release-env.sh lib/git-clean.sh lib/versions.sh; do
    cmp -s "$tree/scripts/$rel" "$tree/packages/dev-config/$rel" || fail "packages/dev-config/$rel is not a copy"
  done
  cmp -s "$tree/.github/zizmor.yml" "$tree/packages/dev-config/zizmor.yml" || fail "packages/dev-config/zizmor.yml is not a copy"
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

# The copies must run from where a consumer has them: node_modules/.../dev-config,
# with lib/ beside checks/ and no repository around them.
packaged_consumer() {
  consumer="$BATS_TEST_TMPDIR/app"
  mkdir -p "$consumer/src/i18n/locales"
  printf 'msgid ""\n' > "$consumer/src/i18n/locales/en.po"
  printf '{"scripts":{"i18n:extract":"%s"}}\n' "$1" > "$consumer/package.json"
  git -C "$consumer" init -q
  git -C "$consumer" -c user.email=t@t -c user.name=t add -A
  git -C "$consumer" -c user.email=t@t -c user.name=t commit -qm init
}

@test "the packaged i18n check runs from the package against a consumer that is current" {
  command -v pnpm >/dev/null || skip "pnpm not installed"
  packaged_consumer "true"
  cd "$consumer"
  run env -u GITHUB_WORKSPACE -u WORKING_DIRECTORY bash "$REPO_ROOT/packages/dev-config/checks/i18n.sh"
  [ "$status" -eq 0 ] || fail "a current consumer failed: $output"
}

@test "the packaged i18n check fails, naming the fix, when extraction changes the catalogs" {
  command -v pnpm >/dev/null || skip "pnpm not installed"
  packaged_consumer "echo changed >> src/i18n/locales/en.po"
  cd "$consumer"
  run env -u GITHUB_WORKSPACE -u WORKING_DIRECTORY bash "$REPO_ROOT/packages/dev-config/checks/i18n.sh"
  [ "$status" -ne 0 ] || fail "stale catalogs passed: $output"
  contains "$output" "run \"pnpm run i18n:extract\" and commit the result" || fail "output: $output"
}
