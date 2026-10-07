#!/usr/bin/env bats
# scripts/security/artifact-prefix.sh - the check check-security.yml's Settings
# job runs on its artifact-prefix input, and the stem it publishes for every
# artifact name of the call. Covers every way out of it: no prefix and an empty
# one (the plain names), a good prefix (the stem with its hyphen, to
# $GITHUB_OUTPUT or to stdout), the 64-character bound on both sides, a prefix
# that is not a plain name (glob characters, capitals, a slash, a space, a
# leading or trailing hyphen), and one containing security-sarif.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

SCRIPT="$REPO_ROOT/scripts/security/artifact-prefix.sh"

@test "artifact-prefix.sh with no argument publishes an empty stem, so the names stay as they were" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$GITHUB_OUTPUT")" = "artifact-prefix=" ] || fail "an absent prefix published: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'security-sarif-<job>' || fail "the log does not say the names are the plain ones: $output"
}

@test "artifact-prefix.sh with an empty prefix publishes an empty stem" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  run bash "$SCRIPT" ""
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$GITHUB_OUTPUT")" = "artifact-prefix=" ] || fail "an empty prefix published: $(cat "$GITHUB_OUTPUT")"
}

@test "artifact-prefix.sh publishes a good prefix with its hyphen" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  run bash "$SCRIPT" my-app-2
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$GITHUB_OUTPUT")" = "artifact-prefix=my-app-2-" ] || fail "the stem is not the prefix and a hyphen: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'my-app-2-security-sarif-<job>' || fail "the log does not name the artifacts: $output"
}

@test "artifact-prefix.sh takes a one-character prefix" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  run bash "$SCRIPT" a
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$GITHUB_OUTPUT")" = "artifact-prefix=a-" ] || fail "a one-character prefix published: $(cat "$GITHUB_OUTPUT")"
}

@test "artifact-prefix.sh writes the stem to stdout when there is no GITHUB_OUTPUT" {
  unset GITHUB_OUTPUT
  run bash "$SCRIPT" my-app
  [ "$status" -eq 0 ] || fail "$output"
  contains "$output" 'artifact-prefix=my-app-' || fail "without GITHUB_OUTPUT the stem did not reach stdout: $output"
}

@test "artifact-prefix.sh takes a prefix of exactly 64 characters" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  prefix="$(printf 'a%.0s' $(seq 1 64))"
  run bash "$SCRIPT" "$prefix"
  [ "$status" -eq 0 ] || fail "a 64-character prefix was refused: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = "artifact-prefix=$prefix-" ] || fail "the 64-character stem is wrong: $(cat "$GITHUB_OUTPUT")"
}

@test "artifact-prefix.sh refuses a prefix of 65 characters, with the fix" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  prefix="$(printf 'a%.0s' $(seq 1 65))"
  run bash "$SCRIPT" "$prefix"
  [ "$status" -eq 1 ] || fail "a 65-character prefix passed: $output"
  contains "$output" '::error::' || fail "the refusal is not an annotation: $output"
  contains "$output" 'is 65 characters long' || fail "the refusal does not say what is wrong: $output"
  contains "$output" 'Fix: pass lowercase letters' || fail "the refusal carries no fix: $output"
  contains "$output" 'consumer-guide.md#check-securityyml' || fail "the refusal does not point at the contract: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a refused prefix still published a stem: $(cat "$GITHUB_OUTPUT")"
}

@test "artifact-prefix.sh refuses a prefix that is not a plain name" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  for prefix in 'app*' 'app?' '[ab]' '{a,b}' '!app' 'My-App' 'app/one' 'app one' 'app_one' 'app.one' '-app' 'app-' '-'; do
    run bash "$SCRIPT" "$prefix"
    [ "$status" -eq 1 ] || fail "the prefix '$prefix' passed: $output"
    contains "$output" "artifact-prefix '$prefix' is not a plain name" || fail "the refusal of '$prefix' does not name it: $output"
    contains "$output" 'Fix: ' || fail "the refusal of '$prefix' carries no fix: $output"
  done
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a refused prefix still published a stem: $(cat "$GITHUB_OUTPUT")"
}

# security-sarif-x would make the unprefixed call's pattern, security-sarif-*,
# match x-security-sarif-code; a-security-sarif would make the prefix a's
# pattern match it. Both contain the text, and that is what is refused.
@test "artifact-prefix.sh refuses a prefix containing security-sarif, which another call's pattern could match" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  for prefix in security-sarif security-sarif-x a-security-sarif x-security-sarif-y; do
    run bash "$SCRIPT" "$prefix"
    [ "$status" -eq 1 ] || fail "the prefix '$prefix' passed: $output"
    contains "$output" "artifact-prefix '$prefix' contains security-sarif" || fail "the refusal of '$prefix' does not say why: $output"
  done
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a refused prefix still published a stem: $(cat "$GITHUB_OUTPUT")"
}

@test "artifact-prefix.sh takes a prefix that mentions security without security-sarif" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  run bash "$SCRIPT" security-app
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$GITHUB_OUTPUT")" = "artifact-prefix=security-app-" ] || fail "security-app published: $(cat "$GITHUB_OUTPUT")"
}
