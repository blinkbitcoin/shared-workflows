#!/usr/bin/env bats
# scripts/ci/resolve-code-scanning-config.sh - the one bash line
# check-code-scanning.yml runs to write the CodeQL configuration. The merge
# itself is tested in packages/app-tooling; this pins the wrapper: the
# arguments reach the program, run from the consumer's root, and a wrong
# argument count is a usage error.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/consumer"
  cd "$BATS_TEST_TMPDIR/consumer" || return 1
}

@test "a consumer with no file gets the family defaults at the output path" {
  run bash "$REPO_ROOT/scripts/ci/resolve-code-scanning-config.sh" .github/codeql/codeql-config.yml .codeql-config.yml
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "resolved the family defaults" || fail "output: $output"
  grep -qxF '  - ".workflows"' .codeql-config.yml || fail "the defaults are not in the file: $(cat .codeql-config.yml)"
}

@test "the consumer's own file is merged over them, whichever path names it" {
  mkdir -p config
  printf 'paths-ignore:\n  - generated\n' > config/codeql.yml
  run bash "$REPO_ROOT/scripts/ci/resolve-code-scanning-config.sh" config/codeql.yml out.yml
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qxF '  - "generated"' out.yml || fail "the consumer's path is missing: $(cat out.yml)"
  grep -qxF '  - ".workflows"' out.yml || fail "the defaults are missing: $(cat out.yml)"
}

@test "a key the merge does not carry fails the step" {
  printf 'paths:\n  - src\n' > codeql.yml
  run bash "$REPO_ROOT/scripts/ci/resolve-code-scanning-config.sh" codeql.yml out.yml
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "sets paths" || fail "output: $output"
  [ ! -e out.yml ] || fail "a file was written anyway"
}

@test "the wrong number of arguments is a usage error" {
  run bash "$REPO_ROOT/scripts/ci/resolve-code-scanning-config.sh" only-one
  [ "$status" -eq 2 ] || fail "expected 2, got $status: $output"
  contains "$output" "usage: resolve-code-scanning-config.sh" || fail "output: $output"
}
