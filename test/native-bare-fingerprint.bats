#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/bare/fingerprint.sh, the bare stack's native fingerprint: a
# sha256 over the platform's tracked native files, the lockfile and the
# NATIVE_EXTRA_GLOBS matches, printed alone like @expo/fingerprint's hash.
# Covered: its shape and stability, what changes it (a tracked native file, the
# lockfile, an extra-glob file, a deletion) and what does not (an untracked
# file, the other platform), the platform from WORKFLOWS_PLATFORM, a missing
# lockfile, nothing tracked, a directory outside git, no git, a failing
# shasum, an unknown platform, a missing working directory and the bare fixture.
load test_helper

setup() {
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP/ios/App" "$APP/android/app"
  git -C "$APP" init -q
  printf 'platform :ios\n' > "$APP/ios/Podfile"
  printf '<plist/>\n' > "$APP/ios/App/Info.plist"
  printf 'applicationId "com.example"\n' > "$APP/android/app/build.gradle"
  printf "lockfileVersion: '9.0'\n" > "$APP/pnpm-lock.yaml"
  git -C "$APP" add -A
  export GITHUB_WORKSPACE="$APP" WORKING_DIRECTORY=.
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
  unset WORKFLOWS_OUT WORKFLOWS_PLATFORM GITHUB_ENV NATIVE_EXTRA_GLOBS
}

fingerprint() { bash "$REPO_ROOT/scripts/native/bare/fingerprint.sh" "$@"; }

@test "prints one sha256, the same on every run, and a different one per platform" {
  run fingerprint ios
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [[ "$output" =~ ^[0-9a-f]{64}$ ]] || fail "not a lone sha256: $output"
  ios="$output"
  [ "$(fingerprint ios)" = "$ios" ] || fail "not stable"
  [ "$(fingerprint android)" != "$ios" ] || fail "the two platforms hashed alike"
  [ "$(WORKFLOWS_PLATFORM=ios fingerprint)" = "$ios" ] || fail "WORKFLOWS_PLATFORM was not read"
}

@test "an edit to a tracked native file changes it, and only for its platform" {
  ios="$(fingerprint ios)"
  android="$(fingerprint android)"
  printf 'platform :ios, "16.0"\n' > "$APP/ios/Podfile"
  [ "$(fingerprint ios)" != "$ios" ] || fail "a Podfile edit left the iOS fingerprint alone"
  [ "$(fingerprint android)" = "$android" ] || fail "an iOS edit moved the Android fingerprint"
}

@test "a file git does not track changes nothing" {
  ios="$(fingerprint ios)"
  mkdir -p "$APP/ios/Pods"
  printf 'generated\n' > "$APP/ios/Pods/Manifest.lock"
  [ "$(fingerprint ios)" = "$ios" ] || fail "an untracked file moved the fingerprint"
}

@test "the lockfile is part of it" {
  android="$(fingerprint android)"
  printf "lockfileVersion: '9.0'\n# a bump\n" > "$APP/pnpm-lock.yaml"
  [ "$(fingerprint android)" != "$android" ] || fail "a lockfile change left the fingerprint alone"
}

@test "NATIVE_EXTRA_GLOBS folds in the matched files' contents, and a glob matching nothing is fine" {
  mkdir -p "$APP/native"
  printf 'one\n' > "$APP/native/a.rb"
  plain="$(fingerprint ios)"
  with="$(NATIVE_EXTRA_GLOBS='native/*.rb nowhere/*' fingerprint ios)"
  [ "$with" != "$plain" ] || fail "the extra glob changed nothing"
  printf 'two\n' > "$APP/native/a.rb"
  [ "$(NATIVE_EXTRA_GLOBS='native/*.rb nowhere/*' fingerprint ios)" != "$with" ] || fail "an edit to a matched file changed nothing"
}

@test "a tracked file deleted in the working tree changes it instead of failing" {
  ios="$(fingerprint ios)"
  rm "$APP/ios/App/Info.plist"
  run fingerprint ios
  [ "$status" -eq 0 ] || fail "a deletion failed the fingerprint: $output"
  [ "$output" != "$ios" ] || fail "a deletion left the fingerprint alone"
}

@test "no lockfile fails with the fix" {
  rm "$APP/pnpm-lock.yaml"
  run fingerprint ios
  [ "$status" -eq 1 ] || fail "fingerprinted without a lockfile: $output"
  contains "$output" "no pnpm-lock.yaml in $(cd "$APP" && pwd -P)" || fail "output: $output"
  contains "$output" "commit the lockfile" || fail "no fix: $output"
}

@test "a platform with nothing tracked fails with the fix" {
  git -C "$APP" rm -q --cached -r android
  run fingerprint android
  [ "$status" -eq 1 ] || fail "fingerprinted an untracked tree: $output"
  contains "$output" "git tracks no file under $(cd "$APP" && pwd -P)/android" || fail "output: $output"
  contains "$output" "pass native-stack: expo" || fail "no fix: $output"
}

@test "outside a git checkout it says git could not list the files" {
  rm -rf "$APP/.git"
  run fingerprint ios
  [ "$status" -eq 1 ] || fail "fingerprinted outside git: $output"
  contains "$output" "git could not list the files under" || fail "output: $output"
}

@test "no git on PATH names the missing command" {
  dir="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$dir"
  for tool in bash dirname mkdir shasum; do ln -sf "$(command -v "$tool")" "$dir/$tool"; done
  PATH="$dir" run fingerprint ios
  [ "$status" -eq 1 ] || fail "ran without git: $output"
  contains "$output" "missing command: git" || fail "output: $output"
}

@test "a shasum that fails on the files fails the fingerprint" {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  real="$(command -v shasum)"
  # Fails when handed files (the per-file pass), works on stdin (the final digest).
  cat > "$bin/shasum" <<SH
#!/usr/bin/env bash
[ "\$#" -le 2 ] || exit 3
exec "$real" "\$@"
SH
  chmod +x "$bin/shasum"
  PATH="$bin:$PATH" run fingerprint ios
  [ "$status" -eq 1 ] || fail "a failed hash passed: $output"
  contains "$output" "could not hash the ios files in" || fail "output: $output"
}

@test "an unknown platform fails before anything is hashed" {
  run fingerprint web
  [ "$status" -eq 1 ] || fail "accepted web: $output"
  contains "$output" "platform must be ios or android (got 'web')" || fail "output: $output"
}

@test "a working directory that does not exist fails" {
  WORKING_DIRECTORY=missing run fingerprint ios
  [ "$status" -eq 1 ] || fail "fingerprinted a missing directory: $output"
  contains "$output" "the consumer's working directory does not exist" || fail "output: $output"
}

@test "the bare fixture fingerprints both platforms" {
  for platform in ios android; do
    GITHUB_WORKSPACE="$FIXTURES/consumer-bare" run fingerprint "$platform"
    [ "$status" -eq 0 ] || fail "$platform: exited $status: $output"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || fail "$platform: $output"
  done
}
