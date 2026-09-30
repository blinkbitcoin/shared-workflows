#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/hooks/install-if-lockfile-changed.sh: the post-merge / post-checkout
# hook that reinstalls dependencies when the lockfile moved. It runs here inside
# a throwaway repository, as lefthook would, with the install replaced by an
# echo: the install itself is the one thing a test must not do.
load test_helper

SCRIPT="$REPO_ROOT/scripts/hooks/install-if-lockfile-changed.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
  export WORKFLOWS_INSTALL_CMD="echo INSTALLED"
  git -C "$REPO" init -q -b main
  commit base 'lockfileVersion: 9'
}

# commit MESSAGE [LOCKFILE-TEXT] - a commit that changes file.txt, and the
# lockfile too when a text is given.
commit() {
  if [ "$#" -gt 1 ]; then printf '%s\n' "$2" > "$REPO/pnpm-lock.yaml"; fi
  printf '%s\n' "$1" > "$REPO/file.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$1"
}

head_sha() { git -C "$REPO" rev-parse HEAD; }

# hook ARGS... - the script, run from inside the repository.
hook() { (cd "$REPO" && bash "$SCRIPT" "$@"); }

@test "post-checkout installs when the two refs differ in the lockfile" {
  local before after
  before="$(head_sha)"
  commit 'bump deps' $'lockfileVersion: 9\npackages: {}'
  after="$(head_sha)"
  run hook post-checkout "$before" "$after" 1
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = $'pnpm-lock.yaml changed: echo INSTALLED\nINSTALLED' ] || fail "output: $output"
}

@test "post-checkout is silent when only other files changed" {
  local before after
  before="$(head_sha)"
  commit 'docs only'
  after="$(head_sha)"
  run hook post-checkout "$before" "$after" 1
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "installed anyway: $output"
}

@test "a file checkout (flag 0) never installs" {
  local before after
  before="$(head_sha)"
  commit 'bump deps again' $'lockfileVersion: 9\npackages: {a: 1}'
  after="$(head_sha)"
  run hook post-checkout "$before" "$after" 0
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "installed on a file checkout: $output"
}

@test "a null old ref (fresh clone) is skipped rather than failing" {
  run hook post-checkout 0000000000000000000000000000000000000000 "$(head_sha)" 1
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "output: $output"
}

@test "post-merge compares ORIG_HEAD with HEAD, not the HEAD@{1} that git rejected" {
  git -C "$REPO" checkout -q -b feature
  commit 'feature bumps the lockfile' $'lockfileVersion: 9\npackages: {b: 2}'
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --no-ff -m 'merge feature' feature
  run hook post-merge 0
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "INSTALLED" || fail "no install after a merge that moved the lockfile: $output"
  not_contains "$output" "ambiguous argument" || fail "output: $output"
}

@test "post-merge without an ORIG_HEAD exits quietly" {
  rm -f "$REPO/.git/ORIG_HEAD"
  run hook post-merge 0
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "output: $output"
}

@test "an unknown hook name fails loudly, with the usage" {
  run hook pre-commit
  [ "$status" -eq 2 ] || fail "expected exit 2, got $status: $output"
  contains "$output" "usage: " || fail "no usage: $output"
  run hook
  [ "$status" -eq 2 ] || fail "no hook name at all: expected exit 2, got $status: $output"
}

@test "from a subdirectory it still reads the repository's own lockfile" {
  local before after
  before="$(head_sha)"
  commit 'bump deps' $'lockfileVersion: 9\npackages: {c: 3}'
  after="$(head_sha)"
  mkdir -p "$REPO/src/deep"
  run bash -c "cd '$REPO/src/deep' && bash '$SCRIPT' post-checkout $before $after 1"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "INSTALLED" || fail "output: $output"
}

@test "WORKFLOWS_LOCKFILE names another lockfile, and the pnpm one is then ignored" {
  local before after
  before="$(head_sha)"
  commit 'bump pnpm deps' $'lockfileVersion: 9\npackages: {d: 4}'
  printf 'lock\n' > "$REPO/package-lock.json"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m 'add npm lockfile'
  after="$(head_sha)"
  WORKFLOWS_LOCKFILE=package-lock.json run hook post-checkout "$before" "$after" 1
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = $'package-lock.json changed: echo INSTALLED\nINSTALLED' ] || fail "output: $output"
  WORKFLOWS_LOCKFILE=package-lock.json run hook post-checkout "$before" "$(git -C "$REPO" rev-parse HEAD~1)" 1
  [ -z "$output" ] || fail "the pnpm lockfile triggered an npm install: $output"
}

@test "a failing install fails the hook with its status" {
  local before after
  before="$(head_sha)"
  commit 'bump deps' $'lockfileVersion: 9\npackages: {e: 5}'
  after="$(head_sha)"
  WORKFLOWS_INSTALL_CMD="bash -c 'exit 3'" run hook post-checkout "$before" "$after" 1
  [ "$status" -ne 0 ] || fail "a failed install passed: $output"
}

@test "outside a repository it fails rather than installing anywhere" {
  run bash -c "cd '$BATS_TEST_TMPDIR' && GIT_CEILING_DIRECTORIES='$BATS_TEST_TMPDIR' bash '$SCRIPT' post-merge 0"
  [ "$status" -ne 0 ] || fail "ran outside a repository: $output"
  not_contains "$output" "INSTALLED" || fail "installed outside a repository: $output"
}
