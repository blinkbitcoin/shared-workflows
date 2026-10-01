#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/generated.sh: the generated-file drift gate this repository
# runs for a consumer that ships no `check:generated` script of its own. It runs
# the consumer's `gen:i18n` and `gen:graphql` scripts, whichever it has, through
# run-script.sh, then fails when one left a modified or untracked file under its
# paths (I18N_PATHS, default src/i18n/locales; GRAPHQL_PATHS, default
# src/graphql/generated).
#
# Covered here: both generators clean, a modified and an untracked output of
# each, a generator that fails, a consumer with only one generator, one with
# neither, the path overrides (one path and several), no git or node on PATH,
# and a working directory that does not exist.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/generated.sh"

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

# A pnpm whose every run writes a line to FILE under the consumer root, which is
# what a generator that disagrees with the committed output looks like.
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
  local scripts='{"scripts":{"gen:graphql":"true","gen:i18n":"true"}}'
  printf '%s\n' "${1:-$scripts}" > "$CONSUMER/package.json"
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

@test "both generators run, and a tree they leave clean passes" {
  stub_pnpm
  git_consumer
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a clean tree must pass: $output"
  run cat "$CALLS"
  [ "$output" = "run gen:i18n
run gen:graphql" ] || fail "expected 'pnpm run gen:i18n' then 'pnpm run gen:graphql': $output"
}

@test "a modified catalog fails the gate and says what to run" {
  git_consumer
  commit_file src/i18n/locales/en/messages.po
  stub_pnpm_writing src/i18n/locales/en/messages.po
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::gen:i18n produced uncommitted or untracked changes in: src/i18n/locales" \
    || fail "the error does not name the generator and the checked path: $output"
  contains "$output" "run \"pnpm run gen:i18n\" and commit the result" || fail "the error does not say what to run: $output"
  contains "$output" "messages.po" || fail "the diff summary does not name the file: $output"
}

@test "an untracked catalog is caught and named, not just a modified one" {
  # assert_clean_paths catches a NEW file where a bare `git diff` would not -
  # the difference the consumer guide calls out.
  git_consumer
  stub_pnpm_writing src/i18n/locales/de/messages.po
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a new catalog must fail the gate: $output"
  contains "$output" "untracked files:" || fail "the untracked file was not reported: $output"
  contains "$output" "de/messages.po" || fail "the untracked file is not named: $output"
}

@test "a modified GraphQL document fails the gate and names gen:graphql" {
  git_consumer
  commit_file src/graphql/generated/graphql.ts
  stub_pnpm_writing src/graphql/generated/graphql.ts
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::gen:graphql produced uncommitted or untracked changes in: src/graphql/generated" \
    || fail "the error does not name the generator and the checked path: $output"
}

@test "an untracked GraphQL document fails the gate as well as a modified one" {
  git_consumer
  stub_pnpm_writing src/graphql/generated/new.ts
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a new generated file must fail the gate: $output"
  contains "$output" "new.ts" || fail "the untracked file is not named: $output"
}

@test "a generator that fails fails the gate before any drift is checked" {
  stub_pnpm
  git_consumer
  WORKFLOWS_TEST_FAILING_SCRIPT="gen:i18n" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a failing generator must fail the gate: $output"
  not_contains "$output" "uncommitted or untracked" || fail "it reached the drift check anyway: $output"
  run cat "$CALLS"
  [ "$output" = "run gen:i18n" ] || fail "gen:graphql ran after gen:i18n failed: $output"
}

@test "a consumer with one generator has only that one checked, and says so" {
  stub_pnpm
  git_consumer '{"scripts":{"gen:graphql":"true"}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "one clean generator must pass: $output"
  contains "$output" 'no "gen:i18n" script' || fail "the skipped generator is not named: $output"
  run cat "$CALLS"
  [ "$output" = "run gen:graphql" ] || fail "expected only gen:graphql: $output"
}

@test "a consumer with neither generator is told to add one or switch the gate off" {
  stub_pnpm
  git_consumer '{"scripts":{}}'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" 'neither a "gen:i18n" nor a "gen:graphql" script' || fail "does not name the missing scripts: $output"
  contains "$output" "generated: false" || fail "does not name the switch: $output"
  [ ! -s "$CALLS" ] || fail "pnpm ran anyway: $(cat "$CALLS")"
}

@test "I18N_PATHS and GRAPHQL_PATHS replace the default paths rather than adding to them" {
  git_consumer
  # A change under a default path is ignored once another path is configured.
  stub_pnpm_writing src/i18n/locales/en/messages.po
  I18N_PATHS="locales" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a change outside the configured path must not fail the gate: $output"

  git_consumer
  stub_pnpm_writing locales/en.json
  I18N_PATHS="locales" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a change under the configured path must fail the gate: $output"
  contains "$output" "changes in: locales " || fail "the error does not name the configured path: $output"

  git_consumer '{"scripts":{"gen:graphql":"true"}}'
  stub_pnpm_writing src/graphql/generated/graphql.ts
  GRAPHQL_PATHS="gql" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a change outside the configured GraphQL path must not fail the gate: $output"
}

@test "an empty I18N_PATHS or GRAPHQL_PATHS is the default, as check.yml passes an unset input" {
  # check.yml sets both from i18n-paths and graphql-paths, which default to ''.
  git_consumer
  stub_pnpm_writing src/i18n/locales/en/messages.po
  I18N_PATHS="" GRAPHQL_PATHS="" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "an empty I18N_PATHS must check the default path: $output"
  contains "$output" "changes in: src/i18n/locales" || fail "the default path is not named: $output"

  git_consumer '{"scripts":{"gen:graphql":"true"}}'
  stub_pnpm_writing src/graphql/generated/graphql.ts
  GRAPHQL_PATHS="" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "an empty GRAPHQL_PATHS must check the default path: $output"
  contains "$output" "changes in: src/graphql/generated" || fail "the default GraphQL path is not named: $output"
}

@test "the paths take several space-separated entries and check each" {
  git_consumer
  stub_pnpm_writing app/locales/fr.po
  I18N_PATHS="src/i18n/locales app/locales" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a change under the second path must fail the gate: $output"
  contains "$output" "changes in: src/i18n/locales app/locales" || fail "the error does not name both paths: $output"

  git_consumer '{"scripts":{"gen:graphql":"true"}}'
  stub_pnpm_writing app/gql/types.ts
  GRAPHQL_PATHS="src/graphql/generated app/gql" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a change under the second GraphQL path must fail the gate: $output"
  contains "$output" "changes in: src/graphql/generated app/gql" || fail "the error does not name both paths: $output"
}

@test "no git or no node on PATH names the missing command" {
  PATH="$(bare_path)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: git" || fail "does not name git: $output"
  PATH="$(bare_path git)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: node" || fail "does not name node: $output"
}

@test "a working directory that does not exist stops the gate before a generator runs" {
  stub_pnpm
  WORKING_DIRECTORY="no-such-directory" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a gate over the wrong directory must not pass: $output"
  [ ! -s "$CALLS" ] || fail "a generator ran anyway: $(cat "$CALLS")"
}
