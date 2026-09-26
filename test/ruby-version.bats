#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/ruby-version.sh: the `setup` composite action publishes the
# consumer's Ruby pin (from its .mise.toml) as the step output `version`, and
# ruby/setup-ruby installs exactly that. A wrong pin builds the lanes against
# the wrong toolchain without anything failing, so every way of not finding the
# pin has to be fatal rather than a guess.
#
# Covers: the pin published to $GITHUB_OUTPUT, read from the consumer rather
# than this repository; printed on stdout when there is no $GITHUB_OUTPUT; and
# fatal with no ruby entry, no mise configuration, or a working directory that
# does not exist.

load test_helper

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"
  export GITHUB_OUTPUT GITHUB_ENV
}

@test "the Ruby pin is read from the consumer's mise config" {
  printf '[tools]\nnode = "24"\nruby = "3.3.6"\n' > "$CONSUMER/.mise.toml"
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "version=3.3.6" ] || fail "wrong pin published: $output"
}

@test "a mise config with no ruby is fatal, naming the tool and the file" {
  # Falling back to a default Ruby would build the lanes against a version
  # nobody chose - the silent-wrong-answer shape this whole file is about.
  printf '[tools]\nnode = "24"\n' > "$CONSUMER/.mise.toml"
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -ne 0 ] || fail "a missing ruby pin must be fatal: $output"
  contains "$output" "ruby" || fail "does not name the tool: $output"
  contains "$output" ".mise.toml" || fail "does not name the file: $output"
}

@test "no mise config at all is fatal rather than an empty pin" {
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -ne 0 ] || fail "must not publish an empty version: $output"
  run cat "$GITHUB_OUTPUT"
  not_contains "$output" "version=" || fail "it published something anyway: $output"
}

@test "the Ruby pin is read from the consumer, not from this repository" {
  # WORKING_DIRECTORY is what makes these scripts act on the caller's checkout.
  # Reading this repo's own .mise.toml would pin every consumer to our Ruby.
  printf '[tools]\nruby = "3.1.0"\n' > "$CONSUMER/.mise.toml"
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "version=3.1.0" ] || fail "did not read the consumer's pin: $output"
}

@test "a working directory that does not exist is fatal and publishes nothing" {
  # The consumer root is resolved inside an argument, where its failure does not
  # stop the script; what stops it is tool-version.sh then finding no file.
  printf '[tools]\nruby = "3.3.6"\n' > "$CONSUMER/.mise.toml"
  WORKING_DIRECTORY="no-such-directory" run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -ne 0 ] || fail "a missing working directory must be fatal: $output"
  contains "$output" "::error::" || fail "no error annotation: $output"
  run cat "$GITHUB_OUTPUT"
  [ -z "$output" ] || fail "it published something anyway: $output"
}

@test "without GITHUB_OUTPUT the pin is printed on stdout" {
  printf '[tools]\nruby = "3.3.6"\n' > "$CONSUMER/.mise.toml"
  unset GITHUB_OUTPUT
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "version=3.3.6" ] || fail "wrong stdout: $output"
}
