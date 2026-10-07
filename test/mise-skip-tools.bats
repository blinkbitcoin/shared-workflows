#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/mise-skip-tools.sh: the `setup` composite action leaves the tools a
# job does not use out of mise. It publishes MISE_DISABLE_TOOLS for the rest of
# the job and a cache-key suffix for mise-action, whose default key does not
# read that variable.
#
# Covers: nothing skipped publishing no variable and an empty suffix (the key
# unchanged); a list published comma-separated, sorted and without repeats,
# whatever order or spacing the caller wrote it in; ruby-enabled adding ruby,
# once, and only when it is 'true'; a name that is not a tool name being fatal
# with nothing published, including a `*` that must not expand against files;
# and stdout when there is no $GITHUB_OUTPUT.

load test_helper

setup() {
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"
  export GITHUB_OUTPUT GITHUB_ENV
  unset SKIP_TOOLS RUBY_ENABLED MISE_DISABLE_TOOLS
}

script() { run bash "$REPO_ROOT/scripts/ci/mise-skip-tools.sh"; }

@test "nothing skipped publishes no variable and an empty suffix" {
  script
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "it published a variable: $(cat "$GITHUB_ENV")"
  [ "$(cat "$GITHUB_OUTPUT")" = "cache-key-suffix=" ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "skipped tools are published comma-separated, with the matching suffix" {
  SKIP_TOOLS="java ruby" script
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_ENV")" = "MISE_DISABLE_TOOLS=java,ruby" ] || fail "wrong variable: $(cat "$GITHUB_ENV")"
  [ "$(cat "$GITHUB_OUTPUT")" = "cache-key-suffix=-without-java-ruby" ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
  contains "$output" "java,ruby" || fail "the log does not say what was skipped: $output"
}

# The same set must always make the same cache key.
@test "order, repeats and spacing do not change what is published" {
  SKIP_TOOLS=$'  ruby\tjava   ruby java ' script
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_ENV")" = "MISE_DISABLE_TOOLS=java,ruby" ] || fail "wrong variable: $(cat "$GITHUB_ENV")"
  [ "$(cat "$GITHUB_OUTPUT")" = "cache-key-suffix=-without-java-ruby" ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "ruby-enabled adds ruby, because setup-ruby provides it" {
  RUBY_ENABLED=true script
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_ENV")" = "MISE_DISABLE_TOOLS=ruby" ] || fail "wrong variable: $(cat "$GITHUB_ENV")"
  [ "$(cat "$GITHUB_OUTPUT")" = "cache-key-suffix=-without-ruby" ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "ruby-enabled and a listed ruby skip it once" {
  SKIP_TOOLS="ruby java" RUBY_ENABLED=true script
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_ENV")" = "MISE_DISABLE_TOOLS=java,ruby" ] || fail "wrong variable: $(cat "$GITHUB_ENV")"
}

@test "ruby-enabled other than 'true' adds nothing" {
  SKIP_TOOLS="java" RUBY_ENABLED=false script
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_ENV")" = "MISE_DISABLE_TOOLS=java" ] || fail "wrong variable: $(cat "$GITHUB_ENV")"
  [ "$(cat "$GITHUB_OUTPUT")" = "cache-key-suffix=-without-java" ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "a name that is not a tool name is fatal and publishes nothing" {
  for bad in "Java" "java,ruby" "-java" "java/ruby"; do
    : > "$GITHUB_OUTPUT"
    SKIP_TOOLS="ruby $bad" script
    [ "$status" -ne 0 ] || fail "'$bad' was accepted: $output"
    contains "$output" "$bad" || fail "the error does not name '$bad': $output"
    [ ! -s "$GITHUB_ENV" ] || fail "'$bad' published a variable: $(cat "$GITHUB_ENV")"
    [ ! -s "$GITHUB_OUTPUT" ] || fail "'$bad' published an output: $(cat "$GITHUB_OUTPUT")"
  done
}

# An unquoted `for name in $SKIP_TOOLS` would expand `*` to these files, which
# are valid tool names, and skip them.
@test "a * is refused, not expanded against the working directory" {
  mkdir -p "$BATS_TEST_TMPDIR/work"
  touch "$BATS_TEST_TMPDIR/work/java" "$BATS_TEST_TMPDIR/work/node"
  cd "$BATS_TEST_TMPDIR/work"
  SKIP_TOOLS="*" script
  [ "$status" -ne 0 ] || fail "'*' was accepted: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "'*' expanded and published: $(cat "$GITHUB_ENV")"
}

@test "without GITHUB_OUTPUT the suffix is printed on stdout" {
  unset GITHUB_OUTPUT GITHUB_ENV
  SKIP_TOOLS="java" script
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "cache-key-suffix=-without-java" || fail "the suffix is not on stdout: $output"
}
