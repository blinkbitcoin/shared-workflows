#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/versions.sh: the tool versions this repository pins, as shell
# variables. It is generated from packages/app-tooling/versions.json by
# scripts/self/render-versions.mjs (whose own test, render-versions.test.mjs,
# holds the committed file to the generator's output), and sourced, not run -
# by yq-version.sh, the installers and check-version-pins.sh, which compares it
# with the workflow input defaults - so what it has to do is define every pin,
# export it to the processes that source it, and do nothing else.
#
# Covers: sourcing it succeeds silently under `set -euo pipefail`; each of the
# thirteen pins is defined, non-empty, shaped like a version and exported to
# child processes; each checksum (the SHA-256 or, where Google publishes only
# that, the SHA-1 of a pinned download) is hex of the right length and
# exported; each of the four setup values that is a name rather than a version
# (the AGP default packages, the AVD and its device, the simulator device type
# prefix) is defined and exported; and every line of the file that is not a
# comment is a plain `export NAME="value"`, so sourcing it cannot run a command. Whether the pins agree with .mise.toml is
# check-version-pins.sh's job, tested in test/plumbing.bats.

load test_helper

PINS="MAESTRO_VERSION ANDROID_API_LEVEL ACTIONLINT_VERSION SHELLCHECK_VERSION YQ_VERSION TYPOS_VERSION LEFTHOOK_VERSION ZIZMOR_VERSION GITLEAKS_VERSION BUNDLETOOL_VERSION ANDROID_CMDLINE_TOOLS_BUILD SETUP_ANDROID_API_LEVEL COCOAPODS_VERSION"
CHECKSUMS="MAESTRO_SHA256"
SHA1_CHECKSUMS="ANDROID_CMDLINE_TOOLS_SHA1_DARWIN_ARM64 ANDROID_CMDLINE_TOOLS_SHA1_DARWIN_X86_64 ANDROID_CMDLINE_TOOLS_SHA1_LINUX"
NAMES="ANDROID_AGP_DEFAULT_PACKAGES SETUP_ANDROID_AVD_NAME SETUP_ANDROID_AVD_DEVICE IOS_SIMULATOR_DEVICE_TYPE_PREFIX"

@test "sourcing it succeeds silently under strict mode" {
  run bash -c 'set -euo pipefail; source "$REPO_ROOT/scripts/lib/versions.sh"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "sourcing printed something: $output"
}

@test "every pin is defined and looks like a version" {
  source "$REPO_ROOT/scripts/lib/versions.sh"
  local name value
  for name in $PINS; do
    value="${!name:-}"
    [ -n "$value" ] || fail "$name is not defined"
    printf '%s' "$value" | grep -qE '^[0-9]+(\.[0-9]+)*$' || fail "$name is not a version: $value"
  done
}

@test "every pin is exported to child processes" {
  local name value
  for name in $PINS; do
    value="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; printenv "$1"' _ "$name")" || true
    [ -n "$value" ] || fail "$name is not exported to a child process"
  done
}

@test "every checksum is a SHA-256 and is exported to child processes" {
  local name value
  for name in $CHECKSUMS; do
    value="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; printenv "$1"' _ "$name")" || true
    [ -n "$value" ] || fail "$name is not exported to a child process"
    printf '%s' "$value" | grep -qE '^[0-9a-f]{64}$' || fail "$name is not a SHA-256: $value"
  done
}

@test "every SHA-1 checksum is 40 hex digits and is exported to child processes" {
  local name value
  for name in $SHA1_CHECKSUMS; do
    value="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; printenv "$1"' _ "$name")" || true
    [ -n "$value" ] || fail "$name is not exported to a child process"
    printf '%s' "$value" | grep -qE '^[0-9a-f]{40}$' || fail "$name is not a SHA-1: $value"
  done
}

@test "every setup name is defined and exported to child processes" {
  local name value
  for name in $NAMES; do
    value="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; printenv "$1"' _ "$name")" || true
    [ -n "$value" ] || fail "$name is not exported to a child process"
  done
}

@test "the file defines exactly the known pins and checksums, and nothing else" {
  # A new pin or checksum is added here in the same change, so it is checked
  # above too. Digits in the name pattern: `MAESTRO_SHA256` has two.
  local declared expected
  declared="$(sed -n 's/^export \([A-Z0-9_]*\)=.*/\1/p' "$REPO_ROOT/scripts/lib/versions.sh" | sort | tr '\n' ' ')"
  expected="$(printf '%s\n' $PINS $CHECKSUMS $SHA1_CHECKSUMS $NAMES | sort | tr '\n' ' ')"
  [ "$declared" = "$expected" ] || fail "declared: $declared; expected: $expected"
}

@test "every line but a comment is a plain export of a quoted value, so sourcing runs no command" {
  local bad
  # A name may hold letters, digits, dots, dashes, slashes, underscores and
  # spaces: nothing a shell expands, quotes or runs.
  bad="$(grep -vnE '^(#.*|export [A-Z_]+="[0-9.]+"|export [A-Z0-9_]+_SHA256="[0-9a-f]{64}"|export [A-Z0-9_]+_SHA1_[A-Z0-9_]+="[0-9a-f]{40}"|export [A-Z_]+="[A-Za-z0-9_./ -]+")$' "$REPO_ROOT/scripts/lib/versions.sh" || true)"
  [ -z "$bad" ] || fail "lines that are not a plain pin: $bad"
}
