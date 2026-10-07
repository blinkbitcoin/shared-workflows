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
# for a heredoc. The fake runs under /bin/bash, named by path, so it still runs
# when a case narrows PATH to the fakes alone. The fakes live in
# $BATS_TEST_TMPDIR/stub-bin, so every test gets its own and parallel tests
# never share one. Stubbing NAME again replaces the fake and keeps its log.
# Like every fake made by as_fakes, it is a link to the shared runner.
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
  rm -f "$dir/$name"
  {
    printf '#!/bin/bash\n'
    printf 'printf '\''%%s\\n'\'' "$*" >> %q\n' "$log"
    printf '%s\n' "$body"
  } > "$dir/$name"
  as_fakes "$dir/$name"
}
# stub_log NAME - the file the fake NAME logs its calls to, one line per call.
stub_log() { printf '%s\n' "$BATS_TEST_TMPDIR/stub-calls/$1.log"; }
# stub_calls NAME - every call the fake NAME received, one line each, oldest first.
stub_calls() { cat "$(stub_log "$1")"; }

# as_fakes FILE... - turn each script FILE a test just wrote into a fake that
# costs no fresh executable: its text moves to .<name>.fake beside it and FILE
# becomes a link to one runner (test/fixtures/fake-runner), which runs that
# text with the call's arguments - a bash fake with FILE as $0, any other under
# the interpreter its `#!` line names. Use it where a test would `chmod +x` a
# fake it wrote.
#
# macOS checks the first run of every newly written executable, one at a time
# across the whole machine (about 90 ms each, never in parallel), so a parallel
# suite writing fresh fakes in every test queued behind itself for minutes. A
# link to an executable that already ran costs nothing. The runner is a
# read-only copy made once per bats run, so a test that writes to a fake's path
# afterwards fails at once instead of rewriting every other test's fakes.
as_fakes() {
  local runner file
  runner="$(fake_runner)" || return
  for file in "$@"; do
    [ -f "$file" ] && [ ! -L "$file" ] || { fail "as_fakes: $file is not a script the test wrote"; return 1; }
    mv -f "$file" "${file%/*}/.${file##*/}.fake"
    ln -s "$runner" "$file"
  done
}
# fake_runner - the path of this bats run's read-only copy of the runner,
# made by the first test that needs it; a rename makes it whole at once.
fake_runner() {
  local runner="$BATS_RUN_TMPDIR/fake-runner" staging
  if [ ! -x "$runner" ]; then
    staging="$(mktemp "$BATS_RUN_TMPDIR/fake-runner.XXXXXX")" || return
    cp "$REPO_ROOT/test/fixtures/fake-runner" "$staging" && chmod 555 "$staging" && mv -f "$staging" "$runner" || return
  fi
  printf '%s\n' "$runner"
}

# contains HAYSTACK NEEDLE / not_contains HAYSTACK NEEDLE - substring checks
# that read as commands, so `|| fail` reads naturally at the call site.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

# wait_for SECONDS WHAT COMMAND [ARG...] - run COMMAND every tenth of a second
# until it succeeds, and fail the test naming WHAT once SECONDS have passed.
#
# For state a background process leaves behind (a log line, a pid file, a
# process gone): the poll returns as soon as the state is there, and fails if
# it never comes, rather than falling through to an assertion that then reads
# a half-written file. The loops this replaced counted iterations and carried on
# silently when they ran out; under a parallel run with every core busy a
# background process can take more than ten seconds to start at all, which
# outlasted them. So the deadline is generous - only a broken test waits it out.
wait_for() {
  local seconds="$1" what="$2" deadline
  shift 2
  deadline=$((SECONDS + seconds))
  until "$@"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "gave up after ${seconds}s waiting for $what"
      return 1
    fi
    sleep 0.1
  done
}

# traced OUTPUT NAME - OUTPUT opened the log group NAME and then carries its
# trace line, `trace: NAME 12.3s` (group and endgroup in scripts/lib/common.sh):
# the phase was timed. Use it as `traced "$output" "Boot simulator" || fail ...`.
traced() {
  local line opened="" timed="" pattern='^trace: (.+) [0-9]+\.[0-9]s$'
  while IFS= read -r line; do
    [ "$line" != "::group::$2" ] || opened=1
    if [ -n "$opened" ] && [[ "$line" =~ $pattern ]] && [ "${BASH_REMATCH[1]}" = "$2" ]; then timed=1; fi
  done <<< "$1"
  [ -n "$opened" ] && [ -n "$timed" ]
}
# summary_beyond_timings FILE - the step summary FILE without the Timings table
# endgroup writes into it, and without blank lines: what else a script wrote
# there. Empty when the script wrote nothing but its timings.
summary_beyond_timings() {
  awk '/^### Timings$/ { timings = 1; next }
    /^$/ { next }
    timings && /^\|/ { next }
    { timings = 0; print }' "$1"
}

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
