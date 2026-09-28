#!/usr/bin/env bats
# scripts/security/verdict-output.sh - turns the consumer's
# .security/verdict.json into the Verdict job's `verdict` output, the value
# publish-badges.yml renders the Security badge from. Covers each rule: the
# file as written, a crashed scanner overriding it, a Verdict step that failed
# without a file, a consumer that writes no file, SECURITY_DIR, and no
# GITHUB_OUTPUT.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  mkdir -p "$GITHUB_WORKSPACE/.security"
  : > "$GITHUB_OUTPUT"
}

verdict_file() { printf '%s\n' "$1" > "$GITHUB_WORKSPACE/.security/verdict.json"; }

@test "the verdict file becomes the output as it is" {
  verdict_file '{"verdict":"informational","highest":"medium","canBlock":true}'
  SCANNER_FAILED=false VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"informational","highest":"medium","canBlock":true}' ] \
    || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "a verdict that failed on findings still reaches the output" {
  verdict_file '{"verdict":"fail","highest":"high","canBlock":true}'
  SCANNER_FAILED=false VERDICT_OUTCOME=failure run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$GITHUB_OUTPUT")" '"verdict":"fail"' || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "a crashed scanner reads as fail even when the merged verdict passed" {
  verdict_file '{"verdict":"pass","highest":"none","canBlock":true}'
  SCANNER_FAILED=true VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"fail"}' ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'scanner job failed' || fail "the override was not explained: $output"
}

@test "a Verdict step that failed without a file reads as fail" {
  SCANNER_FAILED=false VERDICT_OUTCOME=failure run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"fail"}' ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "a consumer that writes no verdict file gets no output, not a false fail" {
  SCANNER_FAILED=false VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "an output was invented: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'verdict.json' || fail "the missing file was not named: $output"
}

@test "SECURITY_DIR moves where the file is read from" {
  mkdir -p "$GITHUB_WORKSPACE/build/security"
  printf '{"verdict":"pass"}\n' > "$GITHUB_WORKSPACE/build/security/verdict.json"
  SECURITY_DIR=build/security SCANNER_FAILED=false VERDICT_OUTCOME=success \
    run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"pass"}' ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "without GITHUB_OUTPUT the value goes to stdout" {
  unset GITHUB_OUTPUT
  verdict_file '{"verdict":"pass"}'
  SCANNER_FAILED=false VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" 'verdict={"verdict":"pass"}' || fail "nothing on stdout: $output"
}
