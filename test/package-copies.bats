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
  contains "$output" "package copies ok (57 files)" || fail "output: $output"
}

# A tree of its own, so the cases below can change originals and copies freely.
tree() {
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/scripts/self" "$tree/scripts/lib" "$tree/scripts/release" "$tree/scripts/checks" "$tree/scripts/ci" "$tree/scripts/hooks" \
    "$tree/scripts/security/lib" "$tree/scripts/security/rules" "$tree/scripts/setup" "$tree/scripts/e2e" "$tree/scripts/native/expo" "$tree/scripts/native/bare" "$tree/.github"
  cp "$REPO_ROOT/scripts/self/package-copies.sh" "$tree/scripts/self/"
  cp "$REPO_ROOT"/scripts/lib/{common,release-env,shared-env,git-clean,versions,e2e-env,e2e-app,e2e-ios,e2e-maestro,e2e-metro,expo-config,native-stack}.sh "$tree/scripts/lib/"
  cp "$REPO_ROOT"/scripts/native/expo/{app-config,fingerprint}.sh "$tree/scripts/native/expo/"
  cp "$REPO_ROOT"/scripts/native/bare/{app-config,fingerprint}.sh "$tree/scripts/native/bare/"
  cp "$REPO_ROOT"/scripts/release/{resolve-version,build-info,verify-ios,verify-android}.sh "$tree/scripts/release/"
  cp "$REPO_ROOT/scripts/release/build-info.mjs" "$tree/scripts/release/"
  cp "$REPO_ROOT/scripts/lib/verify-common.sh" "$tree/scripts/lib/"
  cp "$REPO_ROOT"/scripts/setup/{all,toolchain,android,ios,lib}.sh "$tree/scripts/setup/"
  cp "$REPO_ROOT"/scripts/checks/{generated,secrets,run-script,expo-health}.sh "$tree/scripts/checks/"
  cp "$REPO_ROOT"/scripts/ci/{check-ci,maestro-install}.sh "$tree/scripts/ci/"
  cp "$REPO_ROOT/scripts/hooks/install-if-lockfile-changed.sh" "$tree/scripts/hooks/"
  cp "$REPO_ROOT"/scripts/security/{scan,dependencies,code,policy,sbom,bundle,mobile,binaries,review,review-codebase}.sh "$tree/scripts/security/"
  cp "$REPO_ROOT/scripts/security/lib/runner.sh" "$tree/scripts/security/lib/"
  cp "$REPO_ROOT/scripts/security/rules/react-native-secrets.yaml" "$tree/scripts/security/rules/"
  cp "$REPO_ROOT/scripts/security/semgrepignore" "$tree/scripts/security/"
  cp "$REPO_ROOT"/scripts/e2e/{ios-maestro,android-maestro,app-launch,ios-simulator,android-emulator,collect-forensics,maestro-bound,maestro-suite,wait-for-http}.sh "$tree/scripts/e2e/"
  cp "$REPO_ROOT/.github/zizmor.yml" "$tree/.github/"
}

@test "--write copies every original into the package, and the copies then check clean" {
  tree
  run bash "$tree/scripts/self/package-copies.sh" --write
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "copied 57 files into packages/app-tooling" || fail "output: $output"
  for rel in release/resolve-version.sh release/build-info.sh release/build-info.mjs checks/generated.sh checks/secrets.sh \
    checks/run-script.sh checks/expo-health.sh ci/check-ci.sh ci/maestro-install.sh hooks/install-if-lockfile-changed.sh \
    lib/common.sh lib/release-env.sh lib/git-clean.sh lib/versions.sh security/scan.sh security/code.sh \
    security/review-codebase.sh security/lib/runner.sh security/rules/react-native-secrets.yaml security/semgrepignore release/verify-ios.sh release/verify-android.sh \
    lib/verify-common.sh setup/all.sh setup/lib.sh e2e/ios-maestro.sh e2e/android-maestro.sh e2e/app-launch.sh \
    e2e/ios-simulator.sh e2e/android-emulator.sh e2e/collect-forensics.sh e2e/maestro-bound.sh e2e/maestro-suite.sh e2e/wait-for-http.sh lib/e2e-env.sh \
    lib/shared-env.sh lib/e2e-app.sh lib/e2e-ios.sh lib/e2e-maestro.sh lib/e2e-metro.sh \
    lib/expo-config.sh lib/native-stack.sh native/expo/app-config.sh native/expo/fingerprint.sh \
    native/bare/app-config.sh native/bare/fingerprint.sh; do
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
  require_cmd pnpm
  packaged_consumer "true"
  cd "$consumer"
  run env -u GITHUB_WORKSPACE -u WORKING_DIRECTORY bash "$REPO_ROOT/packages/app-tooling/checks/generated.sh"
  [ "$status" -eq 0 ] || fail "a current consumer failed: $output"
}

@test "the packaged i18n check fails, naming the fix, when extraction changes the catalogs" {
  require_cmd pnpm
  packaged_consumer "echo changed >> src/i18n/locales/en.po"
  cd "$consumer"
  run env -u GITHUB_WORKSPACE -u WORKING_DIRECTORY bash "$REPO_ROOT/packages/app-tooling/checks/generated.sh"
  [ "$status" -ne 0 ] || fail "stale catalogs passed: $output"
  contains "$output" "run \"pnpm run gen:i18n\" and commit the result" || fail "output: $output"
}

# The E2E copies source their libraries and call their siblings relative to
# themselves, so they must run from the package with nothing of this repository
# around them: a developer's `pnpm test:e2e:*` starts them there.
packaged_e2e_consumer() {
  consumer="$BATS_TEST_TMPDIR/app"
  mkdir -p "$consumer/.maestro" "$consumer/android/app/build/outputs/apk/debug" "$BATS_TEST_TMPDIR/bin"
  printf 'apk\n' > "$consumer/android/app/build/outputs/apk/debug/app-debug.apk"
  # An Expo app, detected by the package's own copy of the resolver, which then
  # runs the package's native/expo/app-config.sh.
  printf '{"dependencies":{"expo":"57.0.0"}}\n' > "$consumer/package.json"
  export CALLS="$BATS_TEST_TMPDIR/calls" WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" HOME="$BATS_TEST_TMPDIR/home"
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json"
  printf '{"scheme":"exampleapp","ios":{"bundleIdentifier":"com.example.app"},"android":{"package":"com.example.app"}}\n' > "$EXPO_CONFIG_JSON"
  : > "$CALLS"
  for tool in adb xcrun; do
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$CALLS"\ncase "$*" in *screenrecord*) exit 1 ;; *resolve-activity*) printf "%%s/.MainActivity\\n" "${!#}" ;; esac\n' "$tool" > "$BATS_TEST_TMPDIR/bin/$tool"
  done
  printf '#!/usr/bin/env bash\nprintf packager-status:running\n' > "$BATS_TEST_TMPDIR/bin/curl"
  cat > "$BATS_TEST_TMPDIR/bin/maestro" <<'STUB'
#!/usr/bin/env bash
printf 'maestro %s\n' "$*" >> "$CALLS"
set -- "$@" ""
while [ "$#" -gt 1 ]; do [ "$1" = --output ] && printf '<testsuites tests="1"/>\n' > "$2"; shift; done
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset GITHUB_WORKSPACE WORKING_DIRECTORY
}

@test "the packaged Android suite runs from the package against a consumer, Metro started elsewhere" {
  packaged_e2e_consumer
  cd "$consumer"
  run bash "$REPO_ROOT/packages/app-tooling/e2e/android-maestro.sh" --include-tags smoke
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  calls="$(cat "$CALLS")"
  contains "$calls" "adb install -r $(pwd -P)/android/app/build/outputs/apk/debug/app-debug.apk" || fail "calls: $calls"
  contains "$calls" "exampleapp://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A8081" || fail "calls: $calls"
  contains "$calls" "-e APP_ID=com.example.app" || fail "calls: $calls"
  contains "$calls" "--include-tags smoke" || fail "calls: $calls"
  contains "$output" "Android: Maestro ran 1 flow(s)" || fail "output: $output"
  contains "$output" "native stack: expo (expo is a dependency" || fail "the package's resolver did not decide: $output"
}

@test "the packaged Android suite launches a bare consumer by its applicationId, from the package alone" {
  packaged_e2e_consumer
  printf '{"dependencies":{"react-native":"0.85.2"}}\n' > "$consumer/package.json"
  printf 'android {\n  defaultConfig {\n    applicationId "com.example.bare"\n  }\n}\n' > "$consumer/android/app/build.gradle"
  cd "$consumer"
  WORKFLOWS_DEV_CLIENT=false run bash "$REPO_ROOT/packages/app-tooling/e2e/android-maestro.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  calls="$(cat "$CALLS")"
  contains "$calls" "am start -n com.example.bare/.MainActivity" || fail "calls: $calls"
  contains "$calls" "-e APP_ID=com.example.bare" || fail "calls: $calls"
}

@test "the packaged iOS steps pick, launch and run the suite from the package against a consumer" {
  packaged_e2e_consumer
  export WORKFLOWS_SIM_UDID=SIM-1
  cd "$consumer"
  run bash "$REPO_ROOT/packages/app-tooling/e2e/app-launch.sh" ios
  [ "$status" -eq 0 ] || fail "launch exited $status: $output"
  run bash "$REPO_ROOT/packages/app-tooling/e2e/ios-maestro.sh"
  [ "$status" -eq 0 ] || fail "suite exited $status: $output"
  calls="$(cat "$CALLS")"
  contains "$calls" "xcrun simctl openurl SIM-1 exampleapp://expo-development-client/?url=http%3A%2F%2Flocalhost%3A8081" || fail "calls: $calls"
  contains "$calls" "maestro test .maestro --platform ios --udid SIM-1 -e APP_ID=com.example.app" || fail "calls: $calls"
}
