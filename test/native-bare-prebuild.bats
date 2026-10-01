#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/bare/prebuild.sh: the bare stack generates nothing, it checks
# that the platform's committed project is there and tracked. Covered: a
# tracked tree passes for each platform (the platform from the argument or
# WORKFLOWS_PLATFORM), an absent tree and an untracked one fail with a fix that
# names the input, an unknown platform, and a directory outside git.
load test_helper

setup() {
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP"
  git -C "$APP" init -q
  export GITHUB_WORKSPACE="$APP" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
}

prebuild() { run bash "$REPO_ROOT/scripts/native/bare/prebuild.sh" "$@"; }

commit_tree() {
  mkdir -p "$APP/$1/app"
  printf 'x\n' > "$APP/$1/app/file-one"
  printf 'y\n' > "$APP/$1/app/file-two"
  git -C "$APP" add "$1"
}

@test "a tracked tree passes, for each platform, and says how much is committed" {
  commit_tree ios
  commit_tree android
  for platform in ios android; do
    prebuild "$platform"
    [ "$status" -eq 0 ] || fail "$platform: exited $status: $output"
    contains "$output" "bare native stack: $platform/ is committed (2 tracked files), nothing to generate" || fail "$platform: $output"
  done
}

@test "the platform may come from WORKFLOWS_PLATFORM" {
  commit_tree android
  WORKFLOWS_PLATFORM=android prebuild
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "android/ is committed" || fail "output: $output"
}

@test "an absent tree fails with a fix naming the expo input" {
  prebuild ios
  [ "$status" -eq 1 ] || fail "passed without ios/: $output"
  contains "$output" "no ios/ in $(cd "$APP" && pwd -P), and the bare native stack builds the committed ios/ project" || fail "output: $output"
  contains "$output" "pass native-stack: expo" || fail "no fix: $output"
  contains "$output" "#expo-or-bare" || fail "no contract anchor: $output"
}

@test "a tree git does not track fails: it is not the committed project" {
  mkdir -p "$APP/android/app"
  printf 'x\n' > "$APP/android/app/build.gradle"
  prebuild android
  [ "$status" -eq 1 ] || fail "passed with an untracked android/: $output"
  contains "$output" "android exists but git tracks none of it" || fail "output: $output"
  contains "$output" "commit android/ (and take it out of .gitignore)" || fail "no fix: $output"
}

@test "outside any git repository nothing is tracked, so it fails" {
  rm -rf "$APP/.git"
  mkdir -p "$APP/ios"
  : > "$APP/ios/Podfile"
  prebuild ios
  [ "$status" -eq 1 ] || fail "passed outside git: $output"
  contains "$output" "git tracks none of it" || fail "output: $output"
}

@test "an unknown platform fails before anything is checked" {
  prebuild web
  [ "$status" -ne 0 ] || fail "accepted web: $output"
  contains "$output" "platform must be ios or android (got 'web')" || fail "output: $output"
}
