#!/usr/bin/env bats
# scripts/security/lib/runner.sh - the library every security runner sources.
# Sourcing it moves into the repository being scanned (consumer_root) and sets
# SECURITY_LIB by probing for the security-*.mjs modules: `../../lib` beside it
# when it runs as the package's copy, `../../../packages/app-tooling/lib` when
# it runs from this repository. Then it offers sec_out_dir, sec_skip,
# sec_enabled, sec_require, sec_setting and sec_android_build_tool.
#
# Covers every way out of it: both SECURITY_LIB probes (the real package copy
# and a synthetic tree for each branch), consumer_root under
# GITHUB_WORKSPACE/WORKING_DIRECTORY and its failure; sec_enabled on, off and
# invalid; sec_require present, missing locally and missing under CI;
# sec_setting resolved and invalid; sec_skip's SARIF; and
# sec_android_build_tool from PATH, from the newest ANDROID_HOME (or
# ANDROID_SDK_ROOT) build-tools, and each of its failures - no SDK, no
# build-tools directory, an empty one, a tool that is not executable.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY GITHUB_ACTIONS ANDROID_HOME ANDROID_SDK_ROOT
  # shellcheck disable=SC2046  # one name per word
  unset $(compgen -e | grep '^SECURITY_' || true)
  mkdir -p "$BATS_TEST_TMPDIR/consumer"
  cd "$BATS_TEST_TMPDIR/consumer" || return 1
  consumer="$(pwd -P)"
}

# Runs SNIPPET in a fresh bash that has sourced this repository's runner.sh.
in_runner() {
  run bash -c 'source "$REPO_ROOT/scripts/security/lib/runner.sh" && eval "$1"' _ "$1"
}

# The text of a skipped SARIF's note.
sarif_note() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(d.runs[0].invocations[0].toolExecutionNotifications[0].message.text)' "$1"
}

@test "from this repository SECURITY_LIB is packages/app-tooling/lib, and the runner moves into the consumer" {
  in_runner 'printf "%s\n%s\n" "$SECURITY_LIB" "$PWD"'
  [ "$status" -eq 0 ] || fail "sourcing failed: $output"
  [ "${lines[0]}" = "$(cd "$REPO_ROOT/packages/app-tooling/lib" && pwd -P)" ] || fail "SECURITY_LIB: ${lines[0]}"
  [ "${lines[1]}" = "$consumer" ] || fail "the runner is not in the consumer: ${lines[1]}"
}

@test "the package's copy of runner.sh finds the modules beside it and works" {
  run bash -c 'source "$REPO_ROOT/packages/app-tooling/security/lib/runner.sh" && echo "$SECURITY_LIB" && sec_skip policy "from the package"'
  [ "$status" -eq 0 ] || fail "sourcing the package copy failed: $output"
  [ "${lines[0]}" = "$(cd "$REPO_ROOT/packages/app-tooling/lib" && pwd -P)" ] || fail "SECURITY_LIB: ${lines[0]}"
  [ "$(sarif_note .security/policy.sarif)" = "skipped: from the package" ] || fail "the package copy wrote no skipped SARIF"
}

# The two probes land on the same directory in this repository, so each branch
# is told apart in a tree of its own: one where only ../../lib has the modules
# (the package layout), one where only ../../../packages/app-tooling/lib does.
@test "the probe takes ../../lib when security-sarif.mjs is there (the package layout)" {
  local pkg="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$pkg/security/lib" "$pkg/lib"
  cp "$REPO_ROOT/packages/app-tooling/security/lib/runner.sh" "$pkg/security/lib/runner.sh"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$pkg/lib/common.sh"
  : > "$pkg/lib/security-sarif.mjs"
  run bash -c 'source "$1" && echo "$SECURITY_LIB"' _ "$pkg/security/lib/runner.sh"
  [ "$status" -eq 0 ] || fail "sourcing failed: $output"
  [ "$output" = "$(cd "$pkg/lib" && pwd -P)" ] || fail "SECURITY_LIB: $output"
}

@test "the probe falls back to ../../../packages/app-tooling/lib (this repository's layout)" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/scripts/security/lib" "$ws/scripts/lib" "$ws/packages/app-tooling/lib"
  cp "$REPO_ROOT/scripts/security/lib/runner.sh" "$ws/scripts/security/lib/runner.sh"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$ws/scripts/lib/common.sh"
  run bash -c 'source "$1" && echo "$SECURITY_LIB"' _ "$ws/scripts/security/lib/runner.sh"
  [ "$status" -eq 0 ] || fail "sourcing failed: $output"
  [ "$output" = "$(cd "$ws/packages/app-tooling/lib" && pwd -P)" ] || fail "SECURITY_LIB: $output"
}

@test "under GITHUB_WORKSPACE and WORKING_DIRECTORY the runner moves into that directory" {
  mkdir -p "$BATS_TEST_TMPDIR/workspace/apps/mobile"
  GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/workspace" WORKING_DIRECTORY=apps/mobile in_runner 'pwd'
  [ "$status" -eq 0 ] || fail "sourcing failed: $output"
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/workspace/apps/mobile" && pwd -P)" ] || fail "not in the working directory: $output"
}

@test "a working directory that does not exist fails the sourcing" {
  mkdir -p "$BATS_TEST_TMPDIR/workspace"
  GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/workspace" WORKING_DIRECTORY=missing in_runner 'echo REACHED'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  not_contains "$output" REACHED || fail "the caller ran on after a failed consumer_root: $output"
  contains "$output" missing || fail "the error does not name the directory: $output"
}

@test "sec_out_dir makes .security by default and SECURITY_DIR when set" {
  in_runner 'sec_out_dir'
  [ "$output" = ".security" ] || fail "default: $output"
  [ -d "$consumer/.security" ] || fail "sec_out_dir did not make .security"
  SECURITY_DIR="$BATS_TEST_TMPDIR/out/nested" in_runner 'sec_out_dir'
  [ "$output" = "$BATS_TEST_TMPDIR/out/nested" ] || fail "SECURITY_DIR: $output"
  [ -d "$BATS_TEST_TMPDIR/out/nested" ] || fail "sec_out_dir did not make SECURITY_DIR"
}

@test "sec_skip writes a skipped SARIF for the job and a notice" {
  in_runner 'sec_skip code "nothing to see"'
  [ "$status" -eq 0 ] || fail "sec_skip failed: $output"
  contains "$output" "::notice::code skipped: nothing to see" || fail "no notice: $output"
  [ "$(sarif_note .security/code.sarif)" = "skipped: nothing to see" ] || fail "wrong note in the SARIF"
}

@test "sec_enabled returns for an enabled job" {
  in_runner 'sec_enabled dependencies; echo REACHED'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" REACHED || fail "an enabled job did not return to its caller: $output"
  [ ! -e .security ] || fail "an enabled job wrote a SARIF"
}

@test "sec_enabled skips a disabled job and exits 0" {
  SECURITY_DEPENDENCIES=false in_runner 'sec_enabled dependencies; echo REACHED'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  not_contains "$output" REACHED || fail "a disabled job ran on: $output"
  contains "$(sarif_note .security/dependencies.sarif)" disabled || fail "the skipped SARIF does not say disabled"
}

@test "sec_enabled fails on an invalid setting rather than reading it as disabled" {
  SECURITY_DEPENDENCIES=yes in_runner 'sec_enabled dependencies; echo REACHED'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  not_contains "$output" REACHED || fail "an invalid setting ran on: $output"
  contains "$output" SECURITY_DEPENDENCIES || fail "the error does not name the variable: $output"
  contains "$output" "it does not disable it" || fail "the runner's own message is missing: $output"
  [ ! -e .security ] || fail "an invalid setting wrote a skipped SARIF"
}

@test "sec_require returns when the tool is on PATH" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/bin/some-scanner"
  as_fakes "$BATS_TEST_TMPDIR/bin/some-scanner"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" in_runner 'sec_require some-scanner code; echo REACHED'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" REACHED || fail "a present tool did not return: $output"
  [ ! -e .security ] || fail "a present tool wrote a SARIF"
}

@test "sec_require skips locally when the tool is missing" {
  in_runner 'sec_require no-such-scanner code; echo REACHED'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  not_contains "$output" REACHED || fail "a missing tool ran on: $output"
  [ "$(sarif_note .security/code.sarif)" = "skipped: no-such-scanner is not installed (mise install)" ] ||
    fail "wrong skip note: $(sarif_note .security/code.sarif)"
}

@test "sec_require fails under CI when the tool is missing" {
  CI=true in_runner 'sec_require no-such-scanner code; echo REACHED'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  not_contains "$output" REACHED || fail "a missing tool ran on under CI: $output"
  contains "$output" "no-such-scanner is not installed, and under CI that is a failure" || fail "output: $output"
  [ ! -e .security ] || fail "a CI failure wrote a skipped SARIF"
}

@test "sec_setting prints the resolved value, a list comma-joined" {
  SECURITY_CODE_RULES='rules/a.yml, rules/b' in_runner 'sec_setting options.code.rules'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "rules/a.yml,rules/b" ] || fail "value: $output"
}

@test "sec_setting fails on an invalid value rather than printing nothing" {
  SECURITY_REVIEW_MAX_DIFF_BYTES=lots in_runner 'sec_setting options.review.maxDiffBytes; echo REACHED'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  not_contains "$output" REACHED || fail "an invalid setting ran on: $output"
  contains "$output" SECURITY_REVIEW_MAX_DIFF_BYTES || fail "the error does not name the variable: $output"
  contains "$output" "failed resolving options.review.maxDiffBytes" || fail "the runner's own message is missing: $output"
}

# A build-tools tree under $1 with the versions named after it, each holding an
# executable fake-build-tool.
build_tools() {
  local sdk="$1" version
  shift
  for version in "$@"; do
    mkdir -p "$sdk/build-tools/$version"
    printf '#!/usr/bin/env bash\n' > "$sdk/build-tools/$version/fake-build-tool"
    as_fakes "$sdk/build-tools/$version/fake-build-tool"
  done
}

@test "sec_android_build_tool prefers the tool on PATH" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/bin/fake-build-tool"
  as_fakes "$BATS_TEST_TMPDIR/bin/fake-build-tool"
  build_tools "$BATS_TEST_TMPDIR/sdk" 34.0.0
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" ANDROID_HOME="$BATS_TEST_TMPDIR/sdk" in_runner 'sec_android_build_tool fake-build-tool'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "$BATS_TEST_TMPDIR/bin/fake-build-tool" ] || fail "path: $output"
}

@test "sec_android_build_tool takes the newest ANDROID_HOME build-tools by version, not by text" {
  # A text sort puts 9.0.0 last; sort -V puts 10.0.0 there.
  build_tools "$BATS_TEST_TMPDIR/sdk" 10.0.0 9.0.0 1.2.3
  ANDROID_HOME="$BATS_TEST_TMPDIR/sdk" in_runner 'sec_android_build_tool fake-build-tool'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "$BATS_TEST_TMPDIR/sdk/build-tools/10.0.0/fake-build-tool" ] || fail "path: $output"
}

@test "sec_android_build_tool falls back to ANDROID_SDK_ROOT" {
  build_tools "$BATS_TEST_TMPDIR/sdk-root" 35.0.0
  ANDROID_SDK_ROOT="$BATS_TEST_TMPDIR/sdk-root" in_runner 'sec_android_build_tool fake-build-tool'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$output" = "$BATS_TEST_TMPDIR/sdk-root/build-tools/35.0.0/fake-build-tool" ] || fail "path: $output"
}

@test "sec_android_build_tool fails with no SDK at all" {
  in_runner 'sec_android_build_tool fake-build-tool'
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  [ -z "$output" ] || fail "printed a path: $output"
}

@test "sec_android_build_tool fails when the SDK has no build-tools directory" {
  mkdir -p "$BATS_TEST_TMPDIR/sdk"
  ANDROID_HOME="$BATS_TEST_TMPDIR/sdk" in_runner 'sec_android_build_tool fake-build-tool'
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  [ -z "$output" ] || fail "printed a path: $output"
}

@test "sec_android_build_tool fails when build-tools holds no version" {
  mkdir -p "$BATS_TEST_TMPDIR/sdk/build-tools"
  ANDROID_HOME="$BATS_TEST_TMPDIR/sdk" in_runner 'sec_android_build_tool fake-build-tool'
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  [ -z "$output" ] || fail "printed a path: $output"
}

@test "sec_android_build_tool fails when the newest copy is not executable" {
  build_tools "$BATS_TEST_TMPDIR/sdk" 33.0.0
  mkdir -p "$BATS_TEST_TMPDIR/sdk/build-tools/34.0.0"
  printf 'not a program\n' > "$BATS_TEST_TMPDIR/sdk/build-tools/34.0.0/fake-build-tool"
  ANDROID_HOME="$BATS_TEST_TMPDIR/sdk" in_runner 'sec_android_build_tool fake-build-tool'
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  [ -z "$output" ] || fail "printed a path: $output"
}
