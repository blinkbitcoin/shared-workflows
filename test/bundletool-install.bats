#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# `curl` and `java` are stubbed: what is under test is the pinning and the
# opt-in checksum, not Google's CDN. Google publishes no checksum file next to
# the jar, which is why BUNDLETOOL_SHA256 is opt-in - and why the skip path has
# to say so out loud rather than passing quietly.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/cmd.log"
  : > "$WORKFLOWS_TEST_LOG"
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
prev=""; out=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ "${WORKFLOWS_TEST_CURL_FAIL:-}" = "true" ] && exit 22
[ -n "$out" ] && printf '%s' "${WORKFLOWS_TEST_JAR-jar bytes}" > "$out"
exit 0
SH
  cat > "$STUB/java" <<'SH'
#!/usr/bin/env bash
printf 'java %s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
exit "${WORKFLOWS_TEST_JAVA_STATUS:-0}"
SH
  chmod +x "$STUB/curl" "$STUB/java"
  export PATH="$STUB:$PATH"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp" GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_ENV"
  unset BUNDLETOOL_SHA256
}

install() { run bash "$REPO_ROOT/scripts/ci/bundletool-install.sh"; }

@test "downloads the pinned version and publishes BUNDLETOOL_JAR" {
  BUNDLETOOL_VERSION=1.18.1 install
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(grep '^curl ' "$WORKFLOWS_TEST_LOG")" \
    "https://github.com/google/bundletool/releases/download/1.18.1/bundletool-all-1.18.1.jar" \
    || fail "unexpected url: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -qx "BUNDLETOOL_JAR=$RUNNER_TEMP/bundletool.jar" "$GITHUB_ENV" \
    || fail "BUNDLETOOL_JAR was not published: $(cat "$GITHUB_ENV")"
  contains "$(cat "$WORKFLOWS_TEST_LOG")" "java -jar" || fail "the jar was never run: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "an unset version is fatal" {
  install
  [ "$status" -eq 1 ] || fail "downloaded an unpinned bundletool: $output"
  contains "$output" "::error::missing required environment variable: BUNDLETOOL_VERSION" || fail "unexpected message: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "curl or java ran without a version: $(cat "$WORKFLOWS_TEST_LOG")"
}

# The lane fails much later, and far less obviously, without a JRE.
@test "a runner without java is fatal before the download" {
  rm "$STUB/java"
  # A PATH built from symlinks to exactly the commands the script needs, java
  # excluded: both macOS and the runner images ship a java (or a shim that
  # pretends to be one) in /usr/bin, which would satisfy the lookup and leave
  # this case testing nothing.
  nojava="$BATS_TEST_TMPDIR/nojava"
  mkdir -p "$nojava"
  for c in bash dirname shasum cut ls rm; do
    p="$(command -v "$c")" && ln -sf "$p" "$nojava/$c"
  done
  PATH="$STUB:$nojava" BUNDLETOOL_VERSION=1.18.1 install
  [ "$status" -ne 0 ] || fail "installed bundletool with no JRE: $output"
  contains "$output" "java is not on PATH" || fail "unexpected message: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "downloaded anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a failed download is fatal" {
  WORKFLOWS_TEST_CURL_FAIL=true BUNDLETOOL_VERSION=1.18.1 install
  [ "$status" -ne 0 ] || fail "a failed download was ignored: $output"
  contains "$output" "could not download bundletool" || fail "unexpected message: $output"
}

@test "an empty download is fatal" {
  WORKFLOWS_TEST_JAR='' BUNDLETOOL_VERSION=1.18.1 install
  [ "$status" -ne 0 ] || fail "accepted an empty jar: $output"
  contains "$output" "empty file" || fail "unexpected message: $output"
}

@test "BUNDLETOOL_SHA256 is enforced when set" {
  digest="$(printf 'jar bytes' | shasum -a 256 | cut -d' ' -f1)"
  BUNDLETOOL_VERSION=1.18.1 BUNDLETOOL_SHA256="$digest" install
  [ "$status" -eq 0 ] || fail "the correct digest was rejected: $output"
  contains "$output" "sha256 verified" || fail "unexpected message: $output"
  BUNDLETOOL_VERSION=1.18.1 BUNDLETOOL_SHA256=deadbeef install
  [ "$status" -ne 0 ] || fail "a wrong digest was accepted: $output"
  contains "$output" "sha256 mismatch" || fail "unexpected message: $output"
}

@test "an unset BUNDLETOOL_SHA256 skips verification, loudly" {
  BUNDLETOOL_VERSION=1.18.1 install
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "skipping checksum verification" || fail "the skip was silent: $output"
}

@test "a jar that does not run is fatal" {
  WORKFLOWS_TEST_JAVA_STATUS=1 BUNDLETOOL_VERSION=1.18.1 install
  [ "$status" -ne 0 ] || fail "accepted a jar that does not run: $output"
  contains "$output" "does not run" || fail "unexpected message: $output"
}
