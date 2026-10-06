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

# stub_cmd NAME [BODY | -] - put a fake NAME first on PATH for this test.
#
# The fake appends its arguments, joined by spaces, as one line to its call log
# (`stub_calls NAME` prints it, `stub_log NAME` names the file), then runs BODY
# with the call's arguments in "$@": its output is the fake's output and its
# exit status the fake's. No BODY exits 0 silently; `-` reads BODY from stdin,
# for a heredoc. The fake runs under the bash running the test, named by path,
# so it still runs when a case narrows PATH to the fakes alone. The fakes live
# in $BATS_TEST_TMPDIR/stub-bin, so every test gets its own and parallel tests
# never share one. Stubbing NAME again replaces the fake and keeps its log.
stub_cmd() {
  local name="$1" body="${2:-exit 0}" dir="$BATS_TEST_TMPDIR/stub-bin" log
  [ "$body" != - ] || body="$(cat)"
  log="$(stub_log "$name")"
  mkdir -p "$dir" "${log%/*}"
  [ -f "$log" ] || : > "$log"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
  {
    printf '#!%s\n' "$BASH"
    printf 'printf '\''%%s\\n'\'' "$*" >> %q\n' "$log"
    printf '%s\n' "$body"
  } > "$dir/$name"
  chmod +x "$dir/$name"
}
# stub_log NAME - the file the fake NAME logs its calls to, one line per call.
stub_log() { printf '%s\n' "$BATS_TEST_TMPDIR/stub-calls/$1.log"; }
# stub_calls NAME - every call the fake NAME received, one line each, oldest first.
stub_calls() { cat "$(stub_log "$1")"; }

# contains HAYSTACK NEEDLE / not_contains HAYSTACK NEEDLE - substring checks
# that read as commands, so `|| fail` reads naturally at the call site.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

# require_cmd TOOL... - fail the current test, naming every TOOL not on PATH
# and the fix, instead of skipping it.
#
# Every tool this suite reads the workflows with (yq above all) is pinned in
# .mise.toml, so a missing one is a broken setup, not a reason to skip. The
# guard this replaced, `command -v yq >/dev/null || skip "yq not installed"`,
# turned a shell without the pinned tools into a green run with the workflow
# shape and contract assertions never executed. test/require-cmd.bats fails if
# that guard comes back for a pinned tool.
#
# Named like scripts/lib/common.sh's require_cmd on purpose: the same contract
# (every named command must exist), with a test failure in place of `die`.
require_cmd() {
  local tool missing=""
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    fail "missing command:$missing - this test needs it and fails rather than skips without it. Install the tools .mise.toml pins with 'mise install', then run the suite through 'make test-unit' (or 'mise exec -- bats test/<file>.bats')"
    return 1
  fi
}

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
