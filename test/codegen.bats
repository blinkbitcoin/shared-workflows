#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/codegen.sh: the GraphQL codegen drift gate this repository runs
# for a consumer that ships no `codegen:check` script of its own. It runs the
# consumer's `codegen` script through run-script.sh, then fails when that left a
# modified or untracked file under CODEGEN_PATHS (default src/graphql/generated).
#
# Covered here: a clean regeneration, a modified and an untracked generated
# file, a codegen script that fails, a consumer with no codegen script, the
# CODEGEN_PATHS override (one path and several), no git on PATH, and a working
# directory that does not exist.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/codegen.sh"

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

# A pnpm whose codegen writes a line to FILE under the consumer root, which is
# what a regeneration that disagrees with the committed output looks like.
stub_pnpm_writing() {
  cat > "$STUB/pnpm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$WORKFLOWS_TEST_CALLS"
mkdir -p "\$PWD/$(dirname "$1")"
printf 'regenerated\n' >> "\$PWD/$1"
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
}

git_consumer() {
  git -C "$CONSUMER" init -q -b main
  git -C "$CONSUMER" config user.email test@example.com
  git -C "$CONSUMER" config user.name test
  printf '{"scripts":{"codegen":"true","i18n:extract":"true"}}\n' > "$CONSUMER/package.json"
  git -C "$CONSUMER" add -A
  git -C "$CONSUMER" commit -q -m "init"
}

# Commits FILE under the consumer root, so a later write to it is a modification
# rather than a new file.
commit_file() {
  mkdir -p "$CONSUMER/$(dirname "$1")"
  printf 'committed\n' > "$CONSUMER/$1"
  git -C "$CONSUMER" add -A
  git -C "$CONSUMER" commit -q -m "add $1"
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

@test "the codegen fallback passes when regenerating changes nothing" {
  stub_pnpm
  git_consumer
  run bash "$REPO_ROOT/scripts/checks/codegen.sh"
  [ "$status" -eq 0 ] || fail "a clean tree must pass: $output"
  run cat "$CALLS"
  contains "$output" "codegen" || fail "it did not run codegen: $output"
}

@test "the codegen fallback fails when regenerating leaves a diff" {
  # The whole point of a drift gate: a generated tree that is not what the
  # sources produce. A gate that stops noticing looks exactly like one passing.
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
mkdir -p "$PWD/src/graphql/generated"
printf 'regenerated\n' >> "$PWD/src/graphql/generated/types.ts"
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
  git_consumer
  run bash "$REPO_ROOT/scripts/checks/codegen.sh"
  [ "$status" -ne 0 ] || fail "an uncommitted change must fail the gate: $output"
  contains "$output" "uncommitted or untracked" || fail "it failed for some other reason: $output"
}

@test "the consumer's own codegen script is what runs" {
  stub_pnpm
  git_consumer
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "run codegen" ] || fail "expected exactly 'pnpm run codegen': $output"
}

@test "a modified generated file fails the gate and says what to run" {
  git_consumer
  commit_file src/graphql/generated/types.ts
  stub_pnpm_writing src/graphql/generated/types.ts
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::codegen produced uncommitted or untracked changes in: src/graphql/generated" \
    || fail "the error does not name the checked path: $output"
  contains "$output" "run \"pnpm run codegen\" and commit the result" || fail "the error does not say what to run: $output"
  contains "$output" "types.ts" || fail "the diff summary does not name the file: $output"
}

@test "an untracked generated file fails the gate as well as a modified one" {
  git_consumer
  stub_pnpm_writing src/graphql/generated/new-operation.ts
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a new generated file must fail the gate: $output"
  contains "$output" "untracked files:" || fail "the untracked file was not reported: $output"
  contains "$output" "new-operation.ts" || fail "the untracked file is not named: $output"
}

@test "a codegen script that fails fails the gate before any drift is checked" {
  stub_pnpm
  git_consumer
  WORKFLOWS_TEST_FAILING_SCRIPT="codegen" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a failing codegen must fail the gate: $output"
  not_contains "$output" "uncommitted or untracked" || fail "it reached the drift check anyway: $output"
}

@test "a consumer with no codegen script is told to add one" {
  stub_pnpm
  git_consumer
  printf '{"scripts":{}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "no \"codegen\" script" || fail "does not name the missing script: $output"
  [ ! -s "$CALLS" ] || fail "pnpm ran anyway: $(cat "$CALLS")"
}

@test "CODEGEN_PATHS replaces the default path rather than adding to it" {
  git_consumer
  # A change under the default path is ignored once another path is configured.
  stub_pnpm_writing src/graphql/generated/types.ts
  CODEGEN_PATHS="src/api" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a change outside the configured path must not fail the gate: $output"

  git_consumer
  stub_pnpm_writing src/api/client.ts
  CODEGEN_PATHS="src/api" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a change under the configured path must fail the gate: $output"
  contains "$output" "changes in: src/api " || fail "the error does not name the configured path: $output"
}

@test "CODEGEN_PATHS takes several space-separated paths and checks each" {
  git_consumer
  stub_pnpm_writing src/second/types.ts
  CODEGEN_PATHS="src/first src/second" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a change under the second path must fail the gate: $output"
  contains "$output" "changes in: src/first src/second" || fail "the error does not name both paths: $output"
}

@test "no git on PATH names the missing command" {
  PATH="$(bare_path)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: git" || fail "does not name the missing command: $output"
}

@test "a working directory that does not exist stops the gate before codegen runs" {
  stub_pnpm
  WORKING_DIRECTORY="no-such-directory" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a gate over the wrong directory must not pass: $output"
  [ ! -s "$CALLS" ] || fail "codegen ran anyway: $(cat "$CALLS")"
}
