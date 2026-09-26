#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/versions.sh: the one place this repository writes down the tool
# versions it pins. It is sourced, not run - by yq-version.sh, the installers
# and check-versions.sh, which mirrors it into .mise.toml and the workflow input
# defaults - so what it has to do is define every pin, export it to the
# processes that source it, and do nothing else.
#
# Covers: sourcing it succeeds silently under `set -euo pipefail`; each of the
# ten pins is defined, non-empty, shaped like a version and exported to child
# processes; and every line of the file that is not a comment is a plain
# `export NAME="value"`, so sourcing it cannot run a command. Whether the pins agree with .mise.toml is
# check-versions.sh's job, tested in test/plumbing.bats.

load test_helper

PINS="MAESTRO_VERSION ANDROID_API_LEVEL ACTIONLINT_VERSION SHELLCHECK_VERSION YQ_VERSION TYPOS_VERSION LEFTHOOK_VERSION ZIZMOR_VERSION GITLEAKS_VERSION BUNDLETOOL_VERSION"

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

@test "the file defines exactly the known pins, and nothing else" {
  # A new pin is added here in the same change, so it is checked above too.
  local declared expected
  declared="$(sed -n 's/^export \([A-Z_]*\)=.*/\1/p' "$REPO_ROOT/scripts/lib/versions.sh" | sort | tr '\n' ' ')"
  expected="$(printf '%s\n' $PINS | sort | tr '\n' ' ')"
  [ "$declared" = "$expected" ] || fail "declared: $declared; expected: $expected"
}

@test "every line but a comment is a plain export of a quoted value, so sourcing runs no command" {
  local bad
  bad="$(grep -vnE '^(#.*|export [A-Z_]+="[0-9.]+")$' "$REPO_ROOT/scripts/lib/versions.sh" || true)"
  [ -z "$bad" ] || fail "lines that are not a plain pin: $bad"
}
