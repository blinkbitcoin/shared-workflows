#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# `fastlane` and `bundle` are stubbed with scripts that record their argv and
# the path variables they were handed, because those two things are the whole
# job of this wrapper: fastlane runs a lane with cwd = `fastlane/`, so a
# relative path silently resolves one directory too deep.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  ROOT="$BATS_TEST_TMPDIR/app"
  mkdir -p "$STUB" "$ROOT/fastlane"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/lane.log"
  : > "$WORKFLOWS_TEST_LOG"
  cat > "$STUB/fastlane" <<'SH'
#!/usr/bin/env bash
printf 'argv: %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
for v in WORKFLOWS_OUTPUT_DIR BUILD_INFO_FILE STORE_NOTES_FILE STORE_NOTES_JSON \
  ANDROID_UPLOAD_KEYSTORE_PATH PLAY_SERVICE_ACCOUNT_JSON_PATH ASC_KEY_P8_PATH BUNDLETOOL_JAR; do
  printf '%s=%s\n' "$v" "${!v-}" >> "$WORKFLOWS_TEST_LOG"
done
printf 'argc: %s\n' "$#" >> "$WORKFLOWS_TEST_LOG"
printf 'cwd: %s\n' "$PWD" >> "$WORKFLOWS_TEST_LOG"
printf 'fastlane-directory: %s\n' "${WORKFLOWS_FASTLANE_DIRECTORY-unset}" >> "$WORKFLOWS_TEST_LOG"
printf 'native-stack: %s\n' "${WORKFLOWS_NATIVE_STACK-unset}" >> "$WORKFLOWS_TEST_LOG"
exit 0
SH
  cat > "$STUB/bundle" <<'SH'
#!/usr/bin/env bash
printf 'bundle: %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
printf 'gemfile: %s\n' "${BUNDLE_GEMFILE-unset}" >> "$WORKFLOWS_TEST_LOG"
shift 2  # `exec fastlane`
exec fastlane "$@"
SH
  as_fakes "$STUB/fastlane" "$STUB/bundle"
  export PATH="$STUB:$PATH"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=app
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_ENV LANE_ARGS BUILD_INFO_FILE STORE_NOTES_FILE STORE_NOTES_JSON WORKFLOWS_FASTLANE_DIRECTORY
}

lane() { run bash "$REPO_ROOT/scripts/release/fastlane.sh" "$@"; }

@test "runs the lane on PATH when the consumer has no Gemfile" {
  lane ios build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'argv: ios build' "$WORKFLOWS_TEST_LOG" || fail "unexpected argv: $(cat "$WORKFLOWS_TEST_LOG")"
  ! grep -q '^bundle:' "$WORKFLOWS_TEST_LOG" || fail "used bundler without a Gemfile"
  contains "$output" "unpinned" || fail "the unpinned fastlane was not called out: $output"
}

@test "the lane is told the native stack: the input when there is one" {
  WORKFLOWS_NATIVE_STACK_INPUT=bare lane ios build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'native-stack: bare' "$WORKFLOWS_TEST_LOG" || fail "the stack did not reach the lane: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "the lane is told the native stack: detected from the app when there is no input" {
  printf '{"dependencies":{"expo":"57.0.0"}}' > "$ROOT/package.json"
  unset WORKFLOWS_NATIVE_STACK_INPUT
  lane ios build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'native-stack: expo' "$WORKFLOWS_TEST_LOG" || fail "the stack was not detected: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "an unusable native-stack input fails before any lane runs" {
  WORKFLOWS_NATIVE_STACK_INPUT=flutter lane ios build
  [ "$status" -ne 0 ] || fail "a bad native-stack input ran the lane: $output"
  ! grep -q '^argv:' "$WORKFLOWS_TEST_LOG" || fail "the lane ran anyway"
}

@test "it finds the native stack resolver when run by a relative path" {
  cd "$REPO_ROOT" || fail "cd"
  WORKFLOWS_NATIVE_STACK_INPUT=bare run bash scripts/release/fastlane.sh ios build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'native-stack: bare' "$WORKFLOWS_TEST_LOG" || fail "the stack did not reach the lane"
}

@test "prefers bundle exec when the consumer ships a Gemfile" {
  : > "$ROOT/Gemfile"
  lane android build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q '^bundle: exec fastlane android build$' "$WORKFLOWS_TEST_LOG" \
    || fail "did not go through bundler: $(cat "$WORKFLOWS_TEST_LOG")"
}

# The reason this wrapper exists: a lane's cwd is `fastlane/`, so a relative
# path resolves one directory too deep and the lane reads the wrong file.
@test "every path variable reaches the lane absolute" {
  root="$(cd "$ROOT" && pwd -P)"
  BUILD_INFO_FILE=build-info/build-info.json \
    STORE_NOTES_FILE=build-info/store-notes.txt \
    STORE_NOTES_JSON=build-info/store-notes.json \
    ANDROID_UPLOAD_KEYSTORE_PATH=secrets/upload.jks \
    PLAY_SERVICE_ACCOUNT_JSON_PATH=/already/absolute.json \
    lane android build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "BUILD_INFO_FILE=$root/build-info/build-info.json" "$WORKFLOWS_TEST_LOG" \
    || fail "BUILD_INFO_FILE was not absolutised: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "STORE_NOTES_FILE=$root/build-info/store-notes.txt" "$WORKFLOWS_TEST_LOG" \
    || fail "STORE_NOTES_FILE was not absolutised: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "STORE_NOTES_JSON=$root/build-info/store-notes.json" "$WORKFLOWS_TEST_LOG" \
    || fail "STORE_NOTES_JSON was not absolutised: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "ANDROID_UPLOAD_KEYSTORE_PATH=$root/secrets/upload.jks" "$WORKFLOWS_TEST_LOG" \
    || fail "ANDROID_UPLOAD_KEYSTORE_PATH was not absolutised: $(cat "$WORKFLOWS_TEST_LOG")"
  # An already-absolute path is passed through untouched, not re-rooted.
  grep -qx "PLAY_SERVICE_ACCOUNT_JSON_PATH=/already/absolute.json" "$WORKFLOWS_TEST_LOG" \
    || fail "an absolute path was rewritten: $(cat "$WORKFLOWS_TEST_LOG")"
  # An unset variable stays unset rather than becoming the root directory.
  grep -qx "ASC_KEY_P8_PATH=" "$WORKFLOWS_TEST_LOG" \
    || fail "an unset path variable was invented: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -q "^WORKFLOWS_OUTPUT_DIR=/" "$WORKFLOWS_TEST_LOG" || fail "WORKFLOWS_OUTPUT_DIR is not absolute: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "LANE_ARGS becomes separate argv entries, after the explicit ones" {
  LANE_ARGS='percentage:0.1 track:beta' lane android rollout skip:true
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'argv: android rollout skip:true percentage:0.1 track:beta' "$WORKFLOWS_TEST_LOG" \
    || fail "unexpected argv: $(cat "$WORKFLOWS_TEST_LOG")"
  # The point of the split: two arguments, not one string containing a space.
  grep -qx 'argc: 5' "$WORKFLOWS_TEST_LOG" || fail "LANE_ARGS did not split: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "an empty LANE_ARGS adds no argument at all" {
  LANE_ARGS='' lane ios build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'argc: 2' "$WORKFLOWS_TEST_LOG" || fail "an empty LANE_ARGS became an argument: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "an unknown platform is fatal before anything runs" {
  lane windows build
  [ "$status" -ne 0 ] || fail "accepted an unknown platform: $output"
  contains "$output" "platform must be ios or android" || fail "unexpected message: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "ran a lane anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a missing lane name is fatal" {
  lane ios
  [ "$status" -ne 0 ] || fail "accepted a missing lane: $output"
  contains "$output" "usage" || fail "unexpected message: $output"
}

@test "no Gemfile and no fastlane on PATH is an explicit error" {
  rm "$STUB/fastlane"
  # /usr/bin and /bin only: a fastlane installed on this machine would
  # otherwise satisfy the lookup and the case would not test anything.
  export PATH="$STUB:/usr/bin:/bin"
  lane ios build
  [ "$status" -ne 0 ] || fail "succeeded without fastlane: $output"
  contains "$output" "missing command: fastlane" || fail "unexpected message: $output"
}

# --- the fastlane directory ---------------------------------------------------
#
# fastlane has no option or variable that names its directory: it looks for
# ./fastlane or ./.fastlane under its working directory (FastlaneFolder.path).
# So the lane runs from the directory that contains the fastlane directory.

@test "by default the lane runs from the consumer root, beside fastlane/, which the lanes are told" {
  : > "$ROOT/Gemfile"
  lane ios build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  root="$(cd "$ROOT" && pwd -P)"
  grep -qx "cwd: $root" "$WORKFLOWS_TEST_LOG" || fail "not run from the root: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "gemfile: $root/Gemfile" "$WORKFLOWS_TEST_LOG" || fail "the Gemfile was not named: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "fastlane-directory: fastlane" "$WORKFLOWS_TEST_LOG" || fail "the lanes were not told: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a fastlane directory deeper in the repository runs from its parent, with the root's Gemfile" {
  mkdir -p "$ROOT/mobile/fastlane"
  : > "$ROOT/Gemfile"
  WORKFLOWS_FASTLANE_DIRECTORY=mobile/fastlane/ lane android build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  root="$(cd "$ROOT" && pwd -P)"
  grep -qx "cwd: $root/mobile" "$WORKFLOWS_TEST_LOG" || fail "not run beside mobile/fastlane: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "gemfile: $root/Gemfile" "$WORKFLOWS_TEST_LOG" || fail "the root Gemfile was not used: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "fastlane-directory: mobile/fastlane" "$WORKFLOWS_TEST_LOG" || fail "the lanes were not told: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "running fastlane from $root/mobile (fastlane-directory: mobile/fastlane)" || fail "output: $output"
}

@test "a Gemfile beside the fastlane directory wins over the root's, and a hidden .fastlane is accepted" {
  mkdir -p "$ROOT/mobile/.fastlane"
  : > "$ROOT/Gemfile"
  : > "$ROOT/mobile/Gemfile"
  WORKFLOWS_FASTLANE_DIRECTORY=mobile/.fastlane lane ios build
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  root="$(cd "$ROOT" && pwd -P)"
  grep -qx "gemfile: $root/mobile/Gemfile" "$WORKFLOWS_TEST_LOG" || fail "the nearer Gemfile lost: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a directory fastlane would not find by its name is refused, with the fix" {
  mkdir -p "$ROOT/lanes"
  WORKFLOWS_FASTLANE_DIRECTORY=lanes lane ios build
  [ "$status" -ne 0 ] || fail "accepted a directory fastlane cannot find: $output"
  contains "$output" "fastlane only finds a directory named fastlane or .fastlane" || fail "output: $output"
  contains "$output" "rename the directory to fastlane" || fail "no fix: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "ran a lane anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a fastlane directory outside the consumer is refused" {
  for dir in /etc/fastlane ../fastlane mobile/../../fastlane ..; do
    WORKFLOWS_FASTLANE_DIRECTORY="$dir" lane ios build
    [ "$status" -ne 0 ] || fail "accepted $dir: $output"
    contains "$output" "which is not a directory inside the consumer" || fail "$dir: $output"
  done
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "ran a lane anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a fastlane directory that does not exist is named" {
  rmdir "$ROOT/fastlane"
  lane ios build
  [ "$status" -ne 0 ] || fail "ran without a fastlane directory: $output"
  contains "$output" "no fastlane/ in $(cd "$ROOT" && pwd -P) (the fastlane-directory input)" || fail "output: $output"
}
