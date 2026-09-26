#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/pnpm-install.sh: the dependency install every job that needs the
# consumer's node_modules runs. It installs with --frozen-lockfile in the
# consumer root, and a failed install becomes a contract failure that names the
# lockfile to commit and links the consumer guide.
#
# Covered here: a frozen install in the consumer root, a failed install and
# every part of its message, no pnpm on PATH, and a working directory that does
# not exist (the case the script's two-step `cd` exists for).

load test_helper

SCRIPT="$REPO_ROOT/scripts/ci/pnpm-install.sh"

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

@test "the install runs frozen, in the consumer root" {
  # --frozen-lockfile is the point: CI installs the tree someone reviewed.
  stub_pnpm
  printf '{}\n' > "$CONSUMER/package.json"
  : > "$CONSUMER/pnpm-lock.yaml"
  run bash "$REPO_ROOT/scripts/ci/pnpm-install.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "install --frozen-lockfile" || fail "not a frozen install: $output"
}

@test "a lockfile out of step with package.json is explained, not left to pnpm" {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf 'ERR_PNPM_OUTDATED_LOCKFILE\n' >&2
exit 1
SH
  chmod +x "$STUB/pnpm"
  printf '{}\n' > "$CONSUMER/package.json"
  : > "$CONSUMER/pnpm-lock.yaml"
  PATH="$STUB:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-install.sh"
  [ "$status" -ne 0 ] || fail "a failed install must be fatal: $output"
  contains "$output" "Fix:" || fail "the failure carries no remediation: $output"
  contains "$output" "pnpm-lock.yaml" || fail "does not name what to commit: $output"
}

@test "the install runs in the consumer root, not the directory it was started from" {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$WORKFLOWS_TEST_CALLS"
SH
  chmod +x "$STUB/pnpm"
  cd "$BATS_TEST_TMPDIR"
  PATH="$STUB:$PATH" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "$(cd "$CONSUMER" && pwd -P)|install --frozen-lockfile" ] || fail "wrong directory or arguments: $output"
}

@test "a failed install is one annotation naming the consumer root and linking the guide" {
  stub_pnpm
  WORKFLOWS_TEST_FAILING_SCRIPT="install" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::pnpm install --frozen-lockfile failed in $(cd "$CONSUMER" && pwd -P)" \
    || fail "the annotation does not name the consumer root: $output"
  contains "$output" "%0AFix: if the lockfile is out of date" || fail "the fix is not on its own annotation line: $output"
  contains "$output" "docs/consumer-guide.md#60-second-start" || fail "the guide link is missing its anchor: $output"
}

@test "no pnpm on PATH names the missing command" {
  PATH="$(bare_path)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: pnpm" || fail "does not name the missing command: $output"
}

@test "a working directory that does not exist stops the install rather than installing where the runner stands" {
  # The two-step `cd` in the script exists for this: `cd "$(consumer_root)"`
  # would be `cd ""`, a successful no-op, and pnpm would install elsewhere.
  stub_pnpm
  WORKING_DIRECTORY="no-such-directory" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "an install of the wrong directory must not pass: $output"
  [ ! -s "$CALLS" ] || fail "pnpm ran anyway: $(cat "$CALLS")"
}
