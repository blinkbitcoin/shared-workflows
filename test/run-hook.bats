#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/run-hook.sh: runs the consumer's E2E setup or teardown hook (the
# path in HOOK, relative to the consumer root). A hook runner that treats a
# missing hook as "nothing to do" skips the consumer's setup and fails the
# suite somewhere else entirely. Covered here: HOOK empty and unset (a no-op
# that says so), a hook that runs from the consumer root and is logged, a
# missing hook file (fatal, named), a failing hook (its own status passes
# through) and a working directory that does not exist.

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
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
}

@test "an empty HOOK is a no-op, and says so" {
  HOOK="" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 0 ] || fail "an absent hook is not an error: $output"
  contains "$output" "nothing to run" || fail "$output"
}

@test "a hook that exists runs, from the consumer root" {
  mkdir -p "$CONSUMER/scripts/e2e"
  printf '#!/usr/bin/env bash\nprintf "hook ran in %%s\\n" "$PWD"\n' > "$CONSUMER/scripts/e2e/up.sh"
  chmod +x "$CONSUMER/scripts/e2e/up.sh"
  HOOK="scripts/e2e/up.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "hook ran in" || fail "the hook did not run: $output"
  contains "$output" "consumer" || fail "the hook did not run from the consumer root: $output"
}

@test "a HOOK naming a file that does not exist is fatal" {
  # Deliberately fatal: a silently skipped setup hook produces a confusing
  # suite failure later, somewhere unrelated.
  HOOK="scripts/e2e/missing.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -ne 0 ] || fail "a missing hook must not be skipped: $output"
  contains "$output" "missing.sh" || fail "does not name the path: $output"
}

@test "a hook that fails fails the step" {
  mkdir -p "$CONSUMER/scripts/e2e"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$CONSUMER/scripts/e2e/bad.sh"
  chmod +x "$CONSUMER/scripts/e2e/bad.sh"
  HOOK="scripts/e2e/bad.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -ne 0 ] || fail "a failing hook must not report success: $output"
}

@test "an unset HOOK is a no-op too" {
  unset HOOK
  run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 0 ] || fail "an unset hook is not an error: $status $output"
  contains "$output" "HOOK is empty; nothing to run" || fail "$output"
}

@test "the log names the hook it runs, and the hook runs in the resolved consumer root" {
  mkdir -p "$CONSUMER/scripts/e2e"
  printf '#!/usr/bin/env bash\npwd -P\n' > "$CONSUMER/scripts/e2e/up.sh"
  HOOK="scripts/e2e/up.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "running HOOK: scripts/e2e/up.sh" || fail "the log does not name the hook: $output"
  contains "$output" "$(cd "$CONSUMER" && pwd -P)" || fail "the hook did not run in the consumer root: $output"
}

@test "a missing hook is an error annotation naming the variable and the full path" {
  HOOK="scripts/e2e/missing.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::HOOK points at a missing file: $(cd "$CONSUMER" && pwd -P)/scripts/e2e/missing.sh" ||
    fail "the annotation does not name the variable and the resolved path: $output"
}

@test "a failing hook's own exit status is the step's exit status" {
  mkdir -p "$CONSUMER/scripts/e2e"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$CONSUMER/scripts/e2e/bad.sh"
  HOOK="scripts/e2e/bad.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 3 ] || fail "expected the hook's status 3, got $status: $output"
}

@test "a working directory that does not exist fails before any hook runs" {
  mkdir -p "$CONSUMER/scripts/e2e"
  printf '#!/usr/bin/env bash\necho HOOK-RAN\n' > "$CONSUMER/scripts/e2e/up.sh"
  WORKING_DIRECTORY="nowhere" HOOK="scripts/e2e/up.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -ne 0 ] || fail "an unreachable consumer root must fail: $output"
  not_contains "$output" "HOOK-RAN" || fail "a hook ran from the wrong directory: $output"
}
