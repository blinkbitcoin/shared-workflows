#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/i18n.sh: the translation catalogue drift gate this repository
# runs for a consumer that ships no `i18n:check` script of its own. It runs the
# consumer's `i18n:extract` script through run-script.sh, then fails when that
# left a modified or untracked file under I18N_PATHS (default src/i18n/locales).
#
# Covered here: a clean extraction, a modified and an untracked catalogue, an
# extraction that fails, a consumer with no i18n:extract script, the I18N_PATHS
# override (one path and several), no git on PATH, and a working directory that
# does not exist.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/i18n.sh"

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

# A pnpm whose i18n:extract writes a line to FILE under the consumer root, which
# is what an extraction that disagrees with the committed catalogues looks like.
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

@test "the i18n fallback notices an untracked catalogue, not just a modified one" {
  # assert_clean_paths catches a NEW file where a bare `git diff` would not -
  # the difference the consumer guide calls out.
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
mkdir -p "$PWD/src/i18n/locales"
printf 'new catalogue\n' > "$PWD/src/i18n/locales/de.po"
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
  git_consumer
  run bash "$REPO_ROOT/scripts/checks/i18n.sh"
  [ "$status" -ne 0 ] || fail "an untracked catalogue must fail the gate: $output"
}

@test "the i18n fallback passes when extracting changes nothing, and runs the consumer's own script" {
  stub_pnpm
  git_consumer
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a clean tree must pass: $output"
  run cat "$CALLS"
  [ "$output" = "run i18n:extract" ] || fail "expected exactly 'pnpm run i18n:extract': $output"
}

@test "a modified catalogue fails the gate and says what to run" {
  git_consumer
  commit_file src/i18n/locales/en/messages.po
  stub_pnpm_writing src/i18n/locales/en/messages.po
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::i18n:extract produced uncommitted or untracked changes in: src/i18n/locales" \
    || fail "the error does not name the checked path: $output"
  contains "$output" "run \"pnpm run i18n:extract\" and commit the result" || fail "the error does not say what to run: $output"
  contains "$output" "messages.po" || fail "the diff summary does not name the file: $output"
}

@test "the untracked catalogue is named in the failure" {
  git_consumer
  stub_pnpm_writing src/i18n/locales/de/messages.po
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a new catalogue must fail the gate: $output"
  contains "$output" "untracked files:" || fail "the untracked file was not reported: $output"
  contains "$output" "de/messages.po" || fail "the untracked file is not named: $output"
}

@test "an extraction that fails fails the gate before any drift is checked" {
  stub_pnpm
  git_consumer
  WORKFLOWS_TEST_FAILING_SCRIPT="i18n:extract" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a failing extraction must fail the gate: $output"
  not_contains "$output" "uncommitted or untracked" || fail "it reached the drift check anyway: $output"
}

@test "a consumer with no i18n:extract script is told to add one" {
  stub_pnpm
  git_consumer
  printf '{"scripts":{}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "no \"i18n:extract\" script" || fail "does not name the missing script: $output"
  [ ! -s "$CALLS" ] || fail "pnpm ran anyway: $(cat "$CALLS")"
}

@test "I18N_PATHS replaces the default path rather than adding to it" {
  git_consumer
  # A change under the default path is ignored once another path is configured.
  stub_pnpm_writing src/i18n/locales/en/messages.po
  I18N_PATHS="locales" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a change outside the configured path must not fail the gate: $output"

  git_consumer
  stub_pnpm_writing locales/en.json
  I18N_PATHS="locales" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a change under the configured path must fail the gate: $output"
  contains "$output" "changes in: locales " || fail "the error does not name the configured path: $output"
}

@test "I18N_PATHS takes several space-separated paths and checks each" {
  git_consumer
  stub_pnpm_writing app/locales/fr.po
  I18N_PATHS="src/i18n/locales app/locales" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "a change under the second path must fail the gate: $output"
  contains "$output" "changes in: src/i18n/locales app/locales" || fail "the error does not name both paths: $output"
}

@test "no git on PATH names the missing command" {
  PATH="$(bare_path)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: git" || fail "does not name the missing command: $output"
}

@test "a working directory that does not exist stops the gate before the extraction runs" {
  stub_pnpm
  WORKING_DIRECTORY="no-such-directory" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a gate over the wrong directory must not pass: $output"
  [ ! -s "$CALLS" ] || fail "the extraction ran anyway: $(cat "$CALLS")"
}
