# shellcheck shell=bash
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export REPO_ROOT
FIXTURES="$REPO_ROOT/test/fixtures"
export FIXTURES

# fail MESSAGE - abort the current test with MESSAGE.
#
# Why every assertion in the release test files ends in `|| fail "..."` rather
# than standing on its own:
#
#   bats runs test bodies under `set -e`, but macOS ships bash 3.2 as
#   /bin/bash, and bash 3.2 does NOT honour errexit for a failing `[[ ]]` -
#   a *conditional command*, not a simple command. Verified on this machine:
#
#     bash-3.2 -c 'set -e; f(){ [[ a == b ]]; echo REACHED; }; f'  -> REACHED
#     bash-5.3 -c 'set -e; f(){ [[ a == b ]]; echo REACHED; }; f'  -> aborts
#
#   So a bare mid-body `[[ ]]` assertion silently cannot fail a test locally or
#   on a macOS runner: only the last command's status is observed. `[ ]` (the
#   test builtin, a simple command) is unaffected, which is why this went
#   unnoticed for so long. Routing every assertion through a function call -
#   a simple command - makes it abort under errexit on every bash.
fail() {
  printf '%s\n' "$*" >&2
  return 1
}

# contains HAYSTACK NEEDLE / not_contains HAYSTACK NEEDLE - substring checks
# that read as commands, so `|| fail` reads naturally at the call site.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

# The three variables that decide *where* a script writes, cleared for every
# test in every file.
#
# A GitHub runner sets all three. Scripts in this repo branch on them -
# artifact-summary.sh writes to $GITHUB_STEP_SUMMARY when set and stdout when
# not, gh_output and gh_env do the same for their channels - so a test that
# reads stdout sees nothing on a runner while passing on every laptop. Four
# cases in artifact-summary.bats did exactly that, and only the first real
# Actions run revealed it.
#
# Cleared here rather than per file so a new test file cannot reintroduce it.
# A test that wants one of them set assigns it itself, and that assignment
# still wins - several files rely on exactly that.
unset GITHUB_STEP_SUMMARY GITHUB_OUTPUT GITHUB_ENV

# What git exports into a hook, cleared for every test in every file.
#
# git runs a hook with GIT_DIR (and, from a linked worktree, GIT_WORK_TREE and
# GIT_INDEX_FILE) pointing at the repository being pushed, and those outrank
# both `-C` and the working directory. The pre-push hook runs this suite, so
# every `git init "$tmp"` / `git -C "$tmp" commit` in a test landed in the real
# clone instead: core.bare flipped to true, user.name became `t`, local `main`
# grew a hundred test commits, and `pr`, `side`, `feature` and a row of `v*`
# tags appeared beside the real ones. Run by hand the suite was fine, which is
# why it survived - only a push reproduced it.
#
# `--local-env-vars` is git's own list of the repository-scoped variables, so a
# variable a later git adds is covered without touching this line.
# shellcheck disable=SC2046  # word splitting is the point: one name per word
unset $(git rev-parse --local-env-vars)
