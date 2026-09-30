#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/self/package-copies.sh: the scripts packages/app-tooling ships must be
# byte-identical to the ones the workflows run, or a consumer's laptop resolves
# a version, or passes a check, one way and CI another.
load test_helper

@test "the package's release scripts are the ones the workflows run" {
  run bash "$REPO_ROOT/scripts/self/package-copies.sh"
  [ "$status" -eq 0 ] || fail "stale copies: $output"
  contains "$output" "package copies ok (33 files)" || fail "output: $output"
}

# A tree of its own, so the cases below can change originals and copies freely.
tree() {
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/scripts/self" "$tree/scripts/lib" "$tree/scripts/release" "$tree/scripts/checks" "$tree/scripts/ci" "$tree/scripts/hooks" \
    "$tree/scripts/security/lib" "$tree/scripts/setup" "$tree/.github"
  cp "$REPO_ROOT/scripts/self/package-copies.sh" "$tree/scripts/self/"
  cp "$REPO_ROOT"/scripts/lib/{common,release-env,git-clean,versions}.sh "$tree/scripts/lib/"
  cp "$REPO_ROOT"/scripts/release/{resolve-version,build-info,verify-ios,verify-android}.sh "$tree/scripts/release/"
  cp "$REPO_ROOT/scripts/lib/verify-common.sh" "$tree/scripts/lib/"
  cp "$REPO_ROOT"/scripts/setup/{all,toolchain,android,ios,lib}.sh "$tree/scripts/setup/"
  cp "$REPO_ROOT"/scripts/checks/{generated,secrets,run-script,expo-health}.sh "$tree/scripts/checks/"
  cp "$REPO_ROOT"/scripts/ci/{check-ci,maestro-install}.sh "$tree/scripts/ci/"
  cp "$REPO_ROOT/scripts/hooks/install-if-lockfile-changed.sh" "$tree/scripts/hooks/"
  cp "$REPO_ROOT"/scripts/security/{scan,dependencies,code,policy,sbom,bundle,mobile,binaries,review,review-codebase}.sh "$tree/scripts/security/"
  cp "$REPO_ROOT/scripts/security/lib/runner.sh" "$tree/scripts/security/lib/"
  cp "$REPO_ROOT/.github/zizmor.yml" "$tree/.github/"
}

@test "--write copies every original into the package, and the copies then check clean" {
  tree
  run bash "$tree/scripts/self/package-copies.sh" --write
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "copied 33 files into packages/app-tooling" || fail "output: $output"
  for rel in release/resolve-version.sh release/build-info.sh checks/generated.sh checks/secrets.sh \
    checks/run-script.sh checks/expo-health.sh ci/check-ci.sh ci/maestro-install.sh hooks/install-if-lockfile-changed.sh \
    lib/common.sh lib/release-env.sh lib/git-clean.sh lib/versions.sh security/scan.sh security/code.sh \
    security/review-codebase.sh security/lib/runner.sh release/verify-ios.sh release/verify-android.sh \
    lib/verify-common.sh setup/all.sh setup/lib.sh; do
    cmp -s "$tree/scripts/$rel" "$tree/packages/app-tooling/$rel" || fail "packages/app-tooling/$rel is not a copy"
  done
  cmp -s "$tree/.github/zizmor.yml" "$tree/packages/app-tooling/zizmor.yml" || fail "packages/app-tooling/zizmor.yml is not a copy"
  [ -x "$tree/packages/app-tooling/release/resolve-version.sh" ] || [ ! -x "$tree/scripts/release/resolve-version.sh" ] \
    || fail "the copy lost the original's executable bit"
  run bash "$tree/scripts/self/package-copies.sh"
  [ "$status" -eq 0 ] || fail "fresh copies did not check clean: $output"
}

@test "a changed original, or a missing copy, fails naming each stale copy and the fix" {
  tree
  bash "$tree/scripts/self/package-copies.sh" --write
  printf '# changed\n' >> "$tree/scripts/release/build-info.sh"
  rm "$tree/packages/app-tooling/lib/common.sh"
  run bash "$tree/scripts/self/package-copies.sh"
  [ "$status" -ne 0 ] || fail "stale copies checked clean: $output"
  contains "$output" "packages/app-tooling/release/build-info.sh packages/app-tooling/lib/common.sh" || fail "output: $output"
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

# The copies must run from where a consumer has them: node_modules/.../app-tooling,
# with lib/ beside checks/ and no repository around them.
packaged_consumer() {
  consumer="$BATS_TEST_TMPDIR/app"
  mkdir -p "$consumer/src/i18n/locales"
  printf 'msgid ""\n' > "$consumer/src/i18n/locales/en.po"
  printf '{"scripts":{"gen:i18n":"%s"}}\n' "$1" > "$consumer/package.json"
  git -C "$consumer" init -q
  git -C "$consumer" -c user.email=t@t -c user.name=t add -A
  git -C "$consumer" -c user.email=t@t -c user.name=t commit -qm init
}

@test "the packaged i18n check runs from the package against a consumer that is current" {
  command -v pnpm >/dev/null || skip "pnpm not installed"
  packaged_consumer "true"
  cd "$consumer"
  run env -u GITHUB_WORKSPACE -u WORKING_DIRECTORY bash "$REPO_ROOT/packages/app-tooling/checks/generated.sh"
  [ "$status" -eq 0 ] || fail "a current consumer failed: $output"
}

@test "the packaged i18n check fails, naming the fix, when extraction changes the catalogs" {
  command -v pnpm >/dev/null || skip "pnpm not installed"
  packaged_consumer "echo changed >> src/i18n/locales/en.po"
  cd "$consumer"
  run env -u GITHUB_WORKSPACE -u WORKING_DIRECTORY bash "$REPO_ROOT/packages/app-tooling/checks/generated.sh"
  [ "$status" -ne 0 ] || fail "stale catalogs passed: $output"
  contains "$output" "run \"pnpm run gen:i18n\" and commit the result" || fail "output: $output"
}
