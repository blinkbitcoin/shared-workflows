#!/usr/bin/env bats
load test_helper
setup() { source "$REPO_ROOT/scripts/lib/common.sh"; }
@test "gh_output appends key=value to GITHUB_OUTPUT" {
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"; export GITHUB_OUTPUT
  gh_output hash abc123
  run cat "$GITHUB_OUTPUT"; [ "$output" = "hash=abc123" ]
}
@test "gh_output prints to stdout when GITHUB_OUTPUT is unset" {
  unset GITHUB_OUTPUT
  run gh_output hash abc123; [ "$output" = "hash=abc123" ]
}
@test "die exits 1 with an ::error annotation" {
  run die "boom"; [ "$status" -eq 1 ]; [[ "$output" == *"::error::boom"* ]] || fail "assertion failed; output: $output"
}
@test "die_fix carries the remediation and the contract in one annotation" {
  run die_fix "no mise config in /repo" "add a .mise.toml" "60-second-start"
  [ "$status" -eq 1 ] || fail "die_fix must exit 1; status: $status"
  # One annotation, not three: a second ::error:: would detach from the step.
  [ "$(printf '%s\n' "$output" | grep -c '::error::')" -eq 1 ] || fail "expected one annotation: $output"
  contains "$output" "no mise config in /repo" || fail "$output"
  contains "$output" "%0AFix: add a .mise.toml" || fail "the fix is not on its own line: $output"
  contains "$output" "consumer-guide.md#60-second-start" || fail "no contract link: $output"
}
@test "die_fix without an anchor links the guide itself, not a dangling #" {
  run die_fix "something" "do the thing"
  contains "$output" "Contract: https://github.com/blinkbitcoin/shared-workflows/blob/v0/docs/consumer-guide.md" || fail "expected a guide link: $output"
  not_contains "$output" "consumer-guide.md#" || fail "an empty anchor leaked: $output"
}
@test "die_fix escapes a percent sign so it cannot eat the line breaks" {
  # The annotation encoding is percent-based. Escaping %25 after inserting the
  # %0A newlines would turn each of them into a literal "%0A" in the log.
  run die_fix "coverage fell to 90% of the threshold" "raise it"
  contains "$output" "90%25 of the threshold" || fail "$output"
  contains "$output" "%0AFix: raise it" || fail "the newlines did not survive: $output"
}
@test "gh_env_once appends key=value once, even called twice with the same GITHUB_ENV" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  gh_env_once WORKFLOWS_OUT /tmp/out
  gh_env_once WORKFLOWS_OUT /tmp/out
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ]
  grep -qxF "WORKFLOWS_OUT=/tmp/out" "$GITHUB_ENV"
}
@test "gh_env_once exports the variable even when GITHUB_ENV is unset" {
  unset GITHUB_ENV
  gh_env_once FOO bar
  [ "$FOO" = "bar" ]
}
@test "gh_env writes the plain form for a plain value and exports it" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  gh_env WORKFLOWS_SHA deadbeef
  grep -qx 'WORKFLOWS_SHA=deadbeef' "$GITHUB_ENV" || fail "not the plain form: $(cat "$GITHUB_ENV")"
  [ "$WORKFLOWS_SHA" = "deadbeef" ] || fail "gh_env did not export the value"
}
@test "gh_env routes a newline-bearing value through the heredoc form" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  gh_env NOTES "$(printf 'one\ntwo')"
  head -1 "$GITHUB_ENV" | grep -q '^NOTES<<__workflows_eof_' || fail "not the heredoc form: $(cat "$GITHUB_ENV")"
  delim="$(head -1 "$GITHUB_ENV" | sed 's/^NOTES<<//')"
  [ "$(tail -1 "$GITHUB_ENV")" = "$delim" ] || fail "the block is not closed with its delimiter: $(cat "$GITHUB_ENV")"
  [ "$NOTES" = "$(printf 'one\ntwo')" ] || fail "gh_env did not export the value intact"
}
@test "gh_env_multiline refuses a value carrying its own delimiter" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  # Seeding RANDOM makes the generated delimiter reproducible *within one
  # process* (bash re-seeds it in a subshell), which is the only way a value can
  # be crafted to contain it - so the whole case runs inside one `bash -c`.
  run bash -c '
    source "$1/scripts/lib/common.sh"
    RANDOM=42; delim="__workflows_eof_${RANDOM}${RANDOM}"
    RANDOM=42; gh_env_multiline NOTES "before
$delim
after"
  ' _ "$REPO_ROOT"
  [ "$status" -ne 0 ] || fail "accepted a value containing the delimiter"
  contains "$output" "heredoc delimiter" || fail "unexpected message: $output"
}
@test "consumer_root honours WORKING_DIRECTORY" {
  GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"; WORKING_DIRECTORY=app; export GITHUB_WORKSPACE WORKING_DIRECTORY
  mkdir -p "$BATS_TEST_TMPDIR/app"
  expected="$(cd "$BATS_TEST_TMPDIR/app" && pwd -P)"
  run consumer_root; [ "$output" = "$expected" ]
}
