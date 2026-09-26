#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/build-env.sh: the workflows_publish_build_env function, sourced
# and called the way scripts/release/build-env.sh calls it. Covers each way out
# of the function: returning to the caller when there is nothing to publish,
# publishing and counting the keys, exiting the caller when node is missing or
# the validator rejects the input - with no scratch file left behind either way.
#
# The key rules themselves live in scripts/lib/env-validate.mjs and are asserted
# through the release script in test/build-env.bats (that file is
# scripts/release/build-env.sh's own test) and test/env-json.bats.
load test_helper

setup() {
  export GITHUB_ENV="$BATS_TEST_TMPDIR/gh_env" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_ENV"
  unset WORKFLOWS_BUILD_ENV
}

# Sources the library into a fresh shell, calls the function, then prints a
# marker and the exported values: the marker proves whether the function
# returned to its caller or exited it.
publish_build_env() {
  run bash -c 'source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/build-env.sh"
workflows_publish_build_env
echo "the caller continued: A=${A-unset} B=${B-unset}"'
}

# A PATH holding only bash, so a node installed on this machine cannot satisfy
# the lookup.
only_bash_on_path() {
  local dir="$BATS_TEST_TMPDIR/only-bash"
  mkdir -p "$dir"
  ln -sf "$(command -v bash)" "$dir/bash"
  printf '%s\n' "$dir"
}

@test "an unset or empty-object build environment publishes nothing and returns to the caller" {
  publish_build_env
  [ "$status" -eq 0 ] || fail "exited $status for an unset value: $output"
  contains "$output" "build-env is empty - nothing to publish" || fail "unexpected message: $output"
  contains "$output" "the caller continued" || fail "the function did not return to its caller: $output"
  WORKFLOWS_BUILD_ENV='{}' publish_build_env
  [ "$status" -eq 0 ] || fail "exited $status for an empty object: $output"
  contains "$output" "the caller continued" || fail "the function did not return to its caller: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "wrote something for an empty build environment: $(cat "$GITHUB_ENV")"
}

@test "nothing to publish does not need node" {
  path="$(only_bash_on_path)"
  WORKFLOWS_BUILD_ENV='{}' PATH="$path" publish_build_env
  [ "$status" -eq 0 ] || fail "an empty build environment needed node: $output"
  contains "$output" "the caller continued" || fail "the function did not return to its caller: $output"
}

@test "without node on PATH a build environment to publish is fatal, and names the command" {
  path="$(only_bash_on_path)"
  WORKFLOWS_BUILD_ENV='{"A":"1"}' PATH="$path" publish_build_env
  [ "$status" -ne 0 ] || fail "published without node: $output"
  contains "$output" "missing command: node" || fail "unexpected message: $output"
  not_contains "$output" "the caller continued" || fail "the caller carried on after a missing node: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "wrote to GITHUB_ENV without node: $(cat "$GITHUB_ENV")"
}

@test "every key is published and exported, its name logged, and the count reported" {
  WORKFLOWS_BUILD_ENV='{"A":"1","B":"very-distinctive"}' publish_build_env
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'A=1' "$GITHUB_ENV" || fail "A missing: $(cat "$GITHUB_ENV")"
  grep -qx 'B=very-distinctive' "$GITHUB_ENV" || fail "B missing: $(cat "$GITHUB_ENV")"
  contains "$output" "build-env: A" || fail "the key A was not logged: $output"
  contains "$output" "build-env: B" || fail "the key B was not logged: $output"
  contains "$output" "build-env: published 2 variable(s)" || fail "the count is wrong or missing: $output"
  contains "$output" "the caller continued: A=1 B=very-distinctive" \
    || fail "the values were not exported to the calling shell: $output"
  [ ! -f "$RUNNER_TEMP/workflows-build-env.env" ] || fail "left the scratch file behind"
}

@test "a rejected build environment exits the caller, publishes nothing, and leaves no scratch file" {
  WORKFLOWS_BUILD_ENV='{"1BAD":"x"}' publish_build_env
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "build-env key is not an upper-case env name: 1BAD" || fail "the validator's reason is missing: $output"
  not_contains "$output" "the caller continued" || fail "the caller carried on after a rejection: $output"
  [ ! -s "$GITHUB_ENV" ] || fail "wrote to GITHUB_ENV despite the rejection: $(cat "$GITHUB_ENV")"
  [ ! -f "$RUNNER_TEMP/workflows-build-env.env" ] || fail "left the scratch file behind after a rejection"
}

@test "a value containing a newline is read whole, as one variable" {
  # The validator hands keys and values over NUL-separated; a newline inside a
  # value must not split it into a second pair.
  WORKFLOWS_BUILD_ENV='{"A":"line one\nB=injected"}' publish_build_env
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "build-env: published 1 variable(s)" || fail "the value was split: $output"
  contains "$output" "B=unset" || fail "a second variable was injected: $output"
  grep -q '^A<<__workflows_eof_' "$GITHUB_ENV" || fail "not written in the heredoc form: $(cat "$GITHUB_ENV")"
}

@test "the validator is found beside the library, whatever the working directory" {
  cd "$BATS_TEST_TMPDIR"
  WORKFLOWS_BUILD_ENV='{"A":"1"}' publish_build_env
  [ "$status" -eq 0 ] || fail "could not find the validator from another directory: $output"
  grep -qx 'A=1' "$GITHUB_ENV" || fail "A missing: $(cat "$GITHUB_ENV")"
}
