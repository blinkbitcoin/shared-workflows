#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/audit.sh: the dependency audit this repository runs for a
# consumer that ships no `deps:audit` script of its own. It runs `pnpm audit`
# over production dependencies only, in the consumer root, at AUDIT_LEVEL
# (default high), and its exit status is pnpm's.
#
# Covered here: the default and a configured level, the production-only flag,
# the directory it runs in, a vulnerable tree failing the gate, no pnpm on
# PATH, and a working directory that does not exist.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/audit.sh"

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export WORKFLOWS_TEST_CALLS="$CALLS"
}

# A pnpm that records what it was asked to do and succeeds, unless the test
# names a script that should fail.
stub_pnpm() {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
case " $* " in
  *" ${WORKFLOWS_TEST_FAILING_SCRIPT:-__none__} "*) exit 1 ;;
esac
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
}

# Prints a directory holding only bash, dirname and the named tools, for a PATH
# on which a tool installed on this machine cannot satisfy the lookup a case is
# about.
bare_path() {
  local dir="$BATS_TEST_TMPDIR/bare" tool
  mkdir -p "$dir"
  for tool in bash dirname "$@"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

@test "the audit fallback runs pnpm audit at the configured level" {
  stub_pnpm
  AUDIT_LEVEL=high run bash "$REPO_ROOT/scripts/checks/audit.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "audit" || fail "it did not run an audit: $output"
  contains "$output" "high" || fail "the level was not passed: $output"
}

@test "a vulnerable tree fails the audit gate" {
  stub_pnpm
  WORKFLOWS_TEST_FAILING_SCRIPT="audit" run bash "$REPO_ROOT/scripts/checks/audit.sh"
  [ "$status" -ne 0 ] || fail "a failing audit must fail the gate: $output"
}

@test "with no level configured the audit fails on high and above, production dependencies only" {
  stub_pnpm
  unset AUDIT_LEVEL
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "audit --audit-level high --prod" ] || fail "unexpected pnpm arguments: $output"
}

@test "a configured level reaches pnpm in place of the default" {
  stub_pnpm
  AUDIT_LEVEL=critical run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "audit --audit-level critical --prod" ] || fail "the configured level was not passed: $output"
}

@test "the audit runs in the consumer root, not the directory it was started from" {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >> "$WORKFLOWS_TEST_CALLS"
SH
  chmod +x "$STUB/pnpm"
  cd "$BATS_TEST_TMPDIR"
  PATH="$STUB:$PATH" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "$(cd "$CONSUMER" && pwd -P)" ] || fail "pnpm ran in the wrong directory: $output"
}

@test "the gate exits with the status pnpm audit returned" {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$STUB/pnpm"
  PATH="$STUB:$PATH" run bash "$SCRIPT"
  [ "$status" -eq 7 ] || fail "expected pnpm's status 7, got $status: $output"
}

@test "no pnpm on PATH names the missing command" {
  PATH="$(bare_path)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: pnpm" || fail "does not name the missing command: $output"
}

@test "a working directory that does not exist stops the audit before pnpm runs" {
  stub_pnpm
  WORKING_DIRECTORY="no-such-directory" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "an audit of the wrong directory must not pass: $output"
  [ ! -s "$CALLS" ] || fail "pnpm ran anyway: $(cat "$CALLS")"
}
