#!/usr/bin/env bats
# lefthook.yml and commitlint.config.mjs.
#
# These two files are the only gate that runs on a developer's machine before a
# commit exists, and nothing else in the suite would notice if they rotted:
# a mistyped hook name is silently never installed, and a commitlint pin that
# drifts from scripts/checks/commitlint.sh lets a message pass locally and fail
# in CI (or the reverse, which is worse — it trains people to --no-verify).
load test_helper

CONFIG="$REPO_ROOT/lefthook.yml"
COMMITLINT="$REPO_ROOT/commitlint.config.mjs"
CI_COMMITLINT="$REPO_ROOT/scripts/checks/commitlint.sh"

setup() {
  command -v yq >/dev/null 2>&1 || skip "yq not on PATH (run through 'mise exec --')"
}

# Keys lefthook itself consumes; everything else at the top level is claimed to
# be a git hook name.
NON_HOOK_KEYS='min_version|assert_lefthook_installed|colors|no_tty|skip_output|source_dir|source_dir_local|rc|lefthook|remotes|templates|extends|output'

# The hooks git actually invokes. A name outside this list is installed by
# lefthook into .git/hooks/ and then never called by anything.
GIT_HOOKS='applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change'

@test "every top-level lefthook key is a real git hook or a lefthook setting" {
  run yq -r 'keys | .[]' "$CONFIG"
  [ "$status" -eq 0 ] || fail "lefthook.yml does not parse as YAML: $output"
  bad=""
  while read -r key; do
    [ -n "$key" ] || continue
    if printf '%s\n' "$key" | grep -qxE "$NON_HOOK_KEYS"; then continue; fi
    # shellcheck disable=SC2086 # deliberate word splitting: one hook per line.
    printf '%s\n' $GIT_HOOKS | grep -qxF "$key" || bad="$bad $key"
  done <<<"$output"
  [ -z "$bad" ] || fail "lefthook.yml declares hooks git never calls:$bad"
}

@test "lefthook declares the three hooks this repo relies on" {
  for hook in pre-commit commit-msg pre-push; do
    run yq -r ".\"$hook\" // \"\"" "$CONFIG"
    [ -n "$output" ] || fail "lefthook.yml has no $hook hook"
  done
}

@test "pre-commit skips merge and rebase replays" {
  run yq -r '.["pre-commit"].skip | join(",")' "$CONFIG"
  [ "$output" = "merge,rebase" ] || fail "pre-commit skip is '$output', expected 'merge,rebase'"
}

# The repo has no package.json, so a hook that calls a bare `shellcheck` would
# silently use whatever the developer has on PATH instead of the pinned build.
@test "every pinned tool a hook runs goes through 'mise exec --'" {
  run yq -r '.["pre-commit"].commands | to_entries | .[] | .key + "\t" + .value.run' "$CONFIG"
  [ "$status" -eq 0 ] || fail "cannot read pre-commit commands: $output"
  [ -n "$output" ] || fail "pre-commit has no commands"
  bad=""
  while IFS=$'\t' read -r name cmd; do
    [ -n "$name" ] || continue
    case "$cmd" in "mise exec -- "*) ;; *) bad="$bad $name" ;; esac
  done <<<"$output"
  [ -z "$bad" ] || fail "pre-commit commands not wrapped in 'mise exec --':$bad"
}

# actionlint discovers .github/workflows itself and rejects a file list, so the
# glob is the only thing deciding whether it runs. Passing {staged_files} here
# would make the hook fail on any .github change.
@test "the actionlint hook is glob-gated on .github and takes no file list" {
  run yq -r '.["pre-commit"].commands.actionlint.glob' "$CONFIG"
  contains "$output" ".github" || fail "actionlint glob is '$output', expected a .github glob"
  run yq -r '.["pre-commit"].commands.actionlint.run' "$CONFIG"
  not_contains "$output" "staged_files" || fail "actionlint must not be passed {staged_files}: $output"
}

@test "pre-push runs the full make check" {
  run yq -r '.["pre-push"].commands | to_entries | .[] | .value.run' "$CONFIG"
  contains "$output" "make check" || fail "pre-push does not run 'make check': $output"
}

# The hook and CI must resolve the same commitlint, or a message that passes
# one fails the other. scripts/checks/commitlint.sh is the original; the hook
# copies its invocation, including the doubled -p that is the only form npx
# installs both packages with.
@test "the commit-msg hook pins the same commitlint as scripts/checks/commitlint.sh" {
  run yq -r '.["commit-msg"].commands.commitlint.run' "$CONFIG"
  hook_run="$output"
  contains "$hook_run" "--edit" || fail "commit-msg hook must lint the message file: $hook_run"
  ci_pins="$(grep -oE '@commitlint/[a-z-]+@[0-9]+' "$CI_COMMITLINT" | sort -u)"
  [ -n "$ci_pins" ] || fail "no @commitlint/*@<major> pin found in $CI_COMMITLINT"
  while read -r pin; do
    [ -n "$pin" ] || continue
    contains "$hook_run" "-p $pin" || fail "commit-msg hook is missing '-p $pin' (CI pins it): $hook_run"
  done <<<"$ci_pins"
  hook_pins="$(printf '%s\n' "$hook_run" | grep -oE '@commitlint/[a-z-]+@[0-9]+' | sort -u)"
  [ "$hook_pins" = "$ci_pins" ] || fail "hook pins [$hook_pins] but CI pins [$ci_pins]"
}

@test "the scope enum parses, is sorted and is unique" {
  run node --input-type=module -e "
    const { default: c } = await import('file://$COMMITLINT');
    const [, , scopes] = c.rules['scope-enum'];
    process.stdout.write(scopes.join('\n'));
  "
  [ "$status" -eq 0 ] || fail "commitlint.config.mjs does not load or has no scope-enum: $output"
  [ -n "$output" ] || fail "the scope enum is empty"
  sorted="$(printf '%s\n' "$output" | LC_ALL=C sort)"
  [ "$output" = "$sorted" ] || fail "the scope enum is not sorted; expected:
$sorted"
  uniq_count="$(printf '%s\n' "$output" | LC_ALL=C sort -u | grep -c .)"
  all_count="$(printf '%s\n' "$output" | grep -c .)"
  [ "$uniq_count" = "$all_count" ] || fail "the scope enum has duplicates ($all_count entries, $uniq_count distinct)"
}

# CONTRIBUTING.md and the PR template both spell the scope list out for humans;
# a scope added to the config and nowhere else is a rule nobody can discover.
@test "the scope enum is spelled out in AGENTS.md, CONTRIBUTING.md and the PR template" {
  run node --input-type=module -e "
    const { default: c } = await import('file://$COMMITLINT');
    process.stdout.write(c.rules['scope-enum'][2].join(' '));
  "
  [ "$status" -eq 0 ] || fail "cannot read the scope enum: $output"
  scopes="$output"
  for doc in AGENTS.md CONTRIBUTING.md .github/PULL_REQUEST_TEMPLATE.md; do
    # The list is quoted prose that wraps across lines, so punctuation and
    # newlines collapse to single spaces before matching. Matching the whole
    # sequence (not each scope alone) is what makes this catch a stale copy:
    # words like "docs" and "web" occur all over these files on their own.
    text="$(tr -c 'a-zA-Z0-9-' ' ' < "$REPO_ROOT/$doc" | tr -s ' ')"
    contains "$text" "$scopes" ||
      fail "$doc does not spell out the current scope list: $scopes"
  done
}

@test "lefthook is pinned to an exact version in .mise.toml" {
  grep -qE '^lefthook = "[0-9]+\.[0-9]+\.[0-9]+"$' "$REPO_ROOT/.mise.toml" ||
    fail ".mise.toml must pin lefthook to an exact version (no 'latest')"
}

@test "lefthook-local.yml is gitignored" {
  grep -qxF 'lefthook-local.yml' "$REPO_ROOT/.gitignore" ||
    fail "the documented escape hatch lefthook-local.yml is not in .gitignore"
}

@test "make runs the pinned tools from a shell that activated nothing" {
  command -v mise >/dev/null 2>&1 || skip "mise not installed"
  # A hook started by an IDE or an agent gets this: mise installed, nothing
  # activated. mise alone is linked into an empty bin dir so a tool that also
  # happens to be installed system-wide cannot make this pass. Real targets,
  # not a `command -v` probe: make 3.81 resolves a recipe's command differently
  # from the shell it would hand a probe to.
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$(command -v mise)" "$bin/mise"
  for target in spell lint-workflows tool-versions; do
    run env -i HOME="$HOME" PATH="$bin:/usr/bin:/bin" make -s -C "$REPO_ROOT" "$target"
    [ "$status" -eq 0 ] || fail "'make $target' failed without an activated shell: $output"
  done
}

