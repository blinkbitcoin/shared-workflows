#!/usr/bin/env bats
# Every zizmor command in this repository names its policy with --config.
#
# zizmor looks for zizmor.yml / .github/zizmor.yml at the repository root,
# which it takes to be the nearest directory holding a `.git` *directory*. A
# worktree's `.git` is a file, so from a worktree nested in another checkout
# (Claude Code puts them in `.claude/worktrees/<name>/`) zizmor settles on the
# outer checkout and reads that checkout's policy. When the outer branch has
# none, `unpinned-uses: disable: true` is lost and every tag-pinned `uses:`
# fails the gate on workflow files identical to main. lint-ci.sh's own cases
# are in lint-ci.bats; this holds the commands the repository runs on itself.
load test_helper

# The zizmor command lines in the Makefile and lefthook.yml.
zizmor_commands() {
  grep -hE '(^|[[:space:]])zizmor[[:space:]]+--' "$REPO_ROOT/Makefile" "$REPO_ROOT/lefthook.yml"
}

@test "the Makefile and the hooks both run zizmor" {
  grep -qE 'zizmor[[:space:]]+--' "$REPO_ROOT/Makefile" || fail "no zizmor command in the Makefile"
  grep -qE 'zizmor[[:space:]]+--' "$REPO_ROOT/lefthook.yml" || fail "no zizmor command in lefthook.yml"
}

@test "every zizmor command passes this repository's policy with --config" {
  commands="$(zizmor_commands)"
  [ -n "$commands" ] || fail "found no zizmor command to check"
  missing="$(printf '%s\n' "$commands" | grep -vF -- '--config .github/zizmor.yml' || true)"
  [ -z "$missing" ] || fail "zizmor without --config .github/zizmor.yml:"$'\n'"$missing"
}
