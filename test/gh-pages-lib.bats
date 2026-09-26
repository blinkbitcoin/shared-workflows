#!/usr/bin/env bats
# scripts/ci/gh-pages-lib.sh, sourced, against a throwaway bare remote: its own
# test. Each function it defines is exercised directly:
#
#   * the two exit codes callers branch on (GH_PAGES_NOOP, GH_PAGES_ABSENT);
#   * gh_pages_assert_branch - every name it accepts and each refusal message;
#   * gh_pages_worktree - the orphan on a remote without gh-pages, the absent
#     code with CREATE=0, the existing tip, a reused directory, a stale local
#     branch from a failed push, the commit identity, and a git failure that is
#     not read as "absent";
#   * gh_pages_push - a first-attempt push, a rejected push re-applied onto the
#     fresh tip, a re-apply that reports nothing left to do, a re-apply that
#     fails, the retry budget and its backoff.
#
# The scripts that source it, publish-badges.sh and badges-cleanup.sh, have
# their own files; publish-badges.sh is used here only to put a gh-pages branch
# on the remote. The race is deterministic: `arm_race` installs a pre-receive
# hook on the bare remote that moves gh-pages to a prepared competing commit and
# then rejects our first push.
load test_helper

PUBLISH="$REPO_ROOT/scripts/ci/publish-badges.sh"
LIB="$REPO_ROOT/scripts/ci/gh-pages-lib.sh"

setup() {
  TMP="$(mktemp -d)"
  REMOTE="$TMP/remote.git"
  CONSUMER="$TMP/consumer"
  git init -q --bare "$REMOTE"
  git init -q -b main "$CONSUMER"
  git -C "$CONSUMER" config user.email t@example.com
  git -C "$CONSUMER" config user.name test
  echo "app source" > "$CONSUMER/app.txt"
  git -C "$CONSUMER" add app.txt
  git -C "$CONSUMER" commit -qm "feat: app"
  git -C "$CONSUMER" remote add origin "$REMOTE"
  git -C "$CONSUMER" push -q -u origin main
  render_badges "$CONSUMER" 100%
  export GITHUB_WORKSPACE="$CONSUMER"
  export RUNNER_TEMP="$TMP/runner"
  mkdir -p "$RUNNER_TEMP"
  export GH_PAGES_RETRY_DELAY=0
  export SHA=0123456789abcdef0123456789abcdef01234567
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# The render script's output, stubbed: the publish that seeds gh-pages only
# ever copies files.
render_badges() {
  local root="$1" coverage="$2"
  mkdir -p "$root/coverage/badge"
  for name in unit e2e; do
    printf '<svg>%s</svg>\n' "$name" > "$root/coverage/badge/$name.svg"
    printf '{"label":"%s"}\n' "$name" > "$root/coverage/badge/$name.json"
  done
  printf '<svg>%s</svg>\n' "$coverage" > "$root/coverage/badge/coverage.svg"
}

remote_has_gh_pages() {
  git -C "$REMOTE" rev-parse --verify -q refs/heads/gh-pages >/dev/null
}

# rival_commit BRANCH SUBJECT - build, but do NOT push, a commit on gh-pages
# that another job would have made: it rewrites badges/BRANCH/unit.svg. Prints
# its sha.
rival_commit() {
  local branch="$1" subject="$2" dir="$TMP/rival-$RANDOM"
  git clone -q -b gh-pages "$REMOTE" "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  mkdir -p "$dir/badges/$branch"
  echo "<svg>rival</svg>" > "$dir/badges/$branch/unit.svg"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "$subject"
  # Pushed to a side ref, not to gh-pages: the objects have to be in the bare
  # repo before the hook can point gh-pages at them, but gh-pages itself must
  # not move until our own push is in flight.
  git -C "$dir" push -q origin "HEAD:refs/rivals/$RANDOM$RANDOM"
  git -C "$dir" rev-parse HEAD
}

# arm_race SHA - the next push to the remote finds gh-pages already moved to
# SHA and is rejected; every push after that is accepted. This is the window a
# real concurrent publish opens, made reproducible.
arm_race() {
  local hook="$REMOTE/hooks/pre-receive"
  mkdir -p "$REMOTE/hooks"
  cat > "$hook" <<EOF
#!/bin/sh
cat >/dev/null
[ -f "$TMP/race-fired" ] && exit 0
: > "$TMP/race-fired"
# A pushed ref cannot be updated from inside the push's own quarantine, so the
# move runs as a plain git process against the bare repo.
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_DIR
git --git-dir="$REMOTE" update-ref refs/heads/gh-pages $1 || exit 3
echo "another publish landed first" >&2
exit 1
EOF
  chmod +x "$hook"
}

# reject_every_push - the remote refuses every push from now on.
reject_every_push() {
  cat > "$REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
cat >/dev/null
exit 1
HOOK
  chmod +x "$REMOTE/hooks/pre-receive"
}

# load_library - source the library the way the scripts do, from inside the
# consumer checkout its functions must be called from.
load_library() {
  cd "$CONSUMER"
  source "$REPO_ROOT/scripts/lib/common.sh"
  source "$LIB"
}

# worktree_with_commit - a gh-pages worktree at $RUNNER_TEMP/gh-pages holding
# one new commit that is not on the remote yet.
worktree_with_commit() {
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  echo ours > "$RUNNER_TEMP/gh-pages/ours.txt"
  git -C "$RUNNER_TEMP/gh-pages" add -A
  git -C "$RUNNER_TEMP/gh-pages" commit -qm "chore(ci): ours"
}

# commit_something DIR - a new commit in DIR, so the next push has something to
# send: a re-apply that commits nothing leaves the branch at the remote tip, and
# git then reports the push as up to date instead of letting the hook reject it.
commit_something() {
  echo "$RANDOM$RANDOM" > "$1/attempt.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm "chore(ci): attempt"
}

@test "a push that never succeeds fails loudly instead of reporting success" {
  BRANCH=main bash "$PUBLISH"
  cd "$CONSUMER"
  source "$REPO_ROOT/scripts/lib/common.sh"
  source "$REPO_ROOT/scripts/ci/gh-pages-lib.sh"
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  echo x > "$RUNNER_TEMP/gh-pages/x.txt"
  git -C "$RUNNER_TEMP/gh-pages" add -A
  git -C "$RUNNER_TEMP/gh-pages" commit -qm "chore(ci): badges"
  rm -rf "$REMOTE"
  redo() { return 0; } # there is always more to do: the remote is gone
  GH_PAGES_PUSH_ATTEMPTS=2 run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -ne 0 ] || fail "a push to a vanished remote reported success"
  contains "$output" "could not push gh-pages in 2 attempts" || fail "unexpected error: $output"
}

@test "the no-op and absent codes are 3 and 4, apart from each other and from a plain failure" {
  load_library
  [ "$GH_PAGES_NOOP" = 3 ] || fail "GH_PAGES_NOOP is '$GH_PAGES_NOOP', not 3"
  [ "$GH_PAGES_ABSENT" = 4 ] || fail "GH_PAGES_ABSENT is '$GH_PAGES_ABSENT', not 4"
}

@test "gh_pages_assert_branch accepts ordinary branch names" {
  load_library
  for good in main feat/x release-1.2_rc dependabot/npm_and_yarn/left-pad-1.3.0 v0 a.b; do
    run gh_pages_assert_branch "$good"
    [ "$status" -eq 0 ] || fail "refused the ordinary branch name '$good': $output"
  done
}

@test "gh_pages_assert_branch refuses an empty name and a missing argument" {
  load_library
  run gh_pages_assert_branch ""
  [ "$status" -eq 1 ] || fail "accepted an empty name: $output"
  contains "$output" "::error::BRANCH is empty" || fail "unexpected error: $output"
  run gh_pages_assert_branch
  [ "$status" -eq 1 ] || fail "accepted a missing argument: $output"
  contains "$output" "::error::BRANCH is empty" || fail "unexpected error: $output"
}

@test "gh_pages_assert_branch refuses a name that is not a safe path segment" {
  load_library
  for bad in "-x" "--force" "/abs" "trailing/" ".." "../../etc" "x/../y" "a..b" "a//b"; do
    run gh_pages_assert_branch "$bad"
    [ "$status" -eq 1 ] || fail "accepted '$bad': $output"
    contains "$output" "refusing to use branch name '$bad' as a gh-pages path" \
      || fail "unexpected error for '$bad': $output"
  done
}

@test "gh_pages_assert_branch refuses characters that cannot be a path" {
  load_library
  for bad in "a b" "a:b" "a*b" 'a$b' "a~b" "a\\b" $'a\nb'; do
    run gh_pages_assert_branch "$bad"
    [ "$status" -eq 1 ] || fail "accepted '$bad': $output"
    contains "$output" "has characters that cannot be a gh-pages path" \
      || fail "unexpected error for '$bad': $output"
  done
}

@test "gh_pages_worktree creates gh-pages as an empty orphan when the remote has none" {
  load_library
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  wt="$RUNNER_TEMP/gh-pages"
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = "gh-pages" ] || fail "the worktree is not on gh-pages"
  ! git -C "$wt" rev-parse --verify -q HEAD >/dev/null || fail "the orphan already has a commit"
  [ -z "$(git -C "$wt" ls-files)" ] || fail "the orphan's index carries files: $(git -C "$wt" ls-files)"
  [ ! -e "$wt/app.txt" ] || fail "the orphan's working tree carries the consumer's source"
  [ -z "$(ls -A "$wt" | grep -v '^\.git$')" ] || fail "the orphan's working tree is not empty"
  [ "$(git -C "$CONSUMER" rev-parse --abbrev-ref HEAD)" = "main" ] || fail "the consumer checkout moved"
  ! remote_has_gh_pages || fail "creating the worktree pushed something"
}

@test "gh_pages_worktree with CREATE=0 and no remote branch returns the absent code and creates nothing" {
  load_library
  CREATE=0 run gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  [ "$status" -eq 4 ] || fail "expected the absent code 4, got $status: $output"
  [ ! -e "$RUNNER_TEMP/gh-pages" ] || fail "a worktree was created anyway"
  ! git -C "$CONSUMER" rev-parse --verify -q refs/heads/gh-pages >/dev/null \
    || fail "a local gh-pages branch was created anyway"
}

@test "gh_pages_worktree checks out the remote tip when gh-pages exists" {
  BRANCH=main bash "$PUBLISH"
  load_library
  for create in 1 0; do
    CREATE="$create" gh_pages_worktree "$RUNNER_TEMP/gh-pages"
    wt="$RUNNER_TEMP/gh-pages"
    [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse gh-pages)" ] \
      || fail "the worktree is not at the remote tip with CREATE=$create"
    [ "$(git -C "$wt" symbolic-ref --short HEAD)" = "gh-pages" ] \
      || fail "the worktree is not on a gh-pages branch with CREATE=$create"
    [ -f "$wt/badges/main/unit.svg" ] || fail "the published badges are missing with CREATE=$create"
  done
}

@test "gh_pages_worktree replaces a leftover directory at the same path" {
  BRANCH=main bash "$PUBLISH"
  load_library
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  echo leftover > "$RUNNER_TEMP/gh-pages/leftover.txt"
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  [ ! -e "$RUNNER_TEMP/gh-pages/leftover.txt" ] || fail "the previous run's file survived"
  # A directory deleted behind git's back leaves a stale registration; the
  # prune has to clear it, or `worktree add` refuses the path.
  rm -rf "$RUNNER_TEMP/gh-pages"
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  [ -f "$RUNNER_TEMP/gh-pages/badges/main/unit.svg" ] || fail "the worktree was not recreated"
  [ "$(git -C "$CONSUMER" worktree list | wc -l | tr -d ' ')" = "2" ] \
    || fail "worktrees are stacking: $(git -C "$CONSUMER" worktree list)"
}

@test "gh_pages_worktree deletes a stale local gh-pages branch before taking the orphan path" {
  load_library
  git -C "$CONSUMER" branch gh-pages main
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  ! git -C "$RUNNER_TEMP/gh-pages" rev-parse --verify -q HEAD >/dev/null \
    || fail "the stale branch's history was reused instead of a fresh orphan"
  [ ! -e "$RUNNER_TEMP/gh-pages/app.txt" ] || fail "the stale branch's files were checked out"
}

@test "gh_pages_worktree commits as the GitHub Actions bot without touching the consumer's configuration" {
  load_library
  gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  [ "$GIT_AUTHOR_NAME" = "github-actions[bot]" ] || fail "author name is '$GIT_AUTHOR_NAME'"
  [ "$GIT_COMMITTER_NAME" = "github-actions[bot]" ] || fail "committer name is '$GIT_COMMITTER_NAME'"
  [ "$GIT_AUTHOR_EMAIL" = "41898282+github-actions[bot]@users.noreply.github.com" ] \
    || fail "author email is '$GIT_AUTHOR_EMAIL'"
  [ "$GIT_COMMITTER_EMAIL" = "$GIT_AUTHOR_EMAIL" ] || fail "committer email is '$GIT_COMMITTER_EMAIL'"
  [ "$(git -C "$CONSUMER" config --local user.name)" = "test" ] \
    || fail "the consumer's own identity was rewritten"
  echo x > "$RUNNER_TEMP/gh-pages/x.txt"
  git -C "$RUNNER_TEMP/gh-pages" add -A
  git -C "$RUNNER_TEMP/gh-pages" commit -qm "chore(ci): x"
  [ "$(git -C "$RUNNER_TEMP/gh-pages" log -1 --pretty='%an <%ae>')" \
    = "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ] \
    || fail "the commit was not made as the bot"
}

@test "GH_PAGES_USER_NAME and GH_PAGES_USER_EMAIL override the commit identity" {
  load_library
  GH_PAGES_USER_NAME="Release Bot" GH_PAGES_USER_EMAIL="release@example.com" \
    gh_pages_worktree "$RUNNER_TEMP/gh-pages"
  [ "$GIT_AUTHOR_NAME" = "Release Bot" ] || fail "author name is '$GIT_AUTHOR_NAME'"
  [ "$GIT_COMMITTER_NAME" = "Release Bot" ] || fail "committer name is '$GIT_COMMITTER_NAME'"
  [ "$GIT_AUTHOR_EMAIL" = "release@example.com" ] || fail "author email is '$GIT_AUTHOR_EMAIL'"
  [ "$GIT_COMMITTER_EMAIL" = "release@example.com" ] || fail "committer email is '$GIT_COMMITTER_EMAIL'"
}

# The cleanup calls this inside a `||` list, where errexit does not reach, so
# what matters is the status: a git failure must come back as git's own code,
# never as GH_PAGES_ABSENT, or the caller reads it as nothing to clean.
@test "gh_pages_worktree reports a git failure as a failure, not as the absent code" {
  BRANCH=main bash "$PUBLISH"
  load_library
  : > "$TMP/not-a-directory"
  rc=0
  CREATE=0 gh_pages_worktree "$TMP/not-a-directory/gh-pages" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a worktree under a regular file was reported as created"
  [ "$rc" -ne 4 ] || fail "a git failure was reported as the absent code"
}

@test "gh_pages_push pushes on the first attempt without re-applying" {
  load_library
  worktree_with_commit
  redo() { : > "$TMP/redo-called"; }
  run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -eq 0 ] || fail "push failed: $output"
  [ ! -e "$TMP/redo-called" ] || fail "the re-apply step ran although the push was accepted"
  not_contains "$output" "rejected" || fail "a retry was logged for an accepted push: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$(git -C "$RUNNER_TEMP/gh-pages" rev-parse HEAD)" ] \
    || fail "the remote is not at the pushed commit"
}

@test "gh_pages_push re-applies onto the fresh tip after a rejection, then pushes" {
  BRANCH=main bash "$PUBLISH"
  load_library
  worktree_with_commit
  rival="$(rival_commit main "chore(ci): rival")"
  arm_race "$rival"
  redo() {
    echo ours > "$1/ours.txt"
    git -C "$1" add -A
    git -C "$1" commit -qm "chore(ci): ours, re-applied"
  }
  run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -eq 0 ] || fail "the retry never converged: $output"
  contains "$output" "push attempt 1 of 5 was rejected; re-applying onto origin/gh-pages" \
    || fail "no retry notice: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages~1)" = "$rival" ] \
    || fail "the re-applied commit does not sit on the rival's commit"
  [ "$(git -C "$REMOTE" log -1 --pretty=%s gh-pages)" = "chore(ci): ours, re-applied" ] \
    || fail "the re-applied commit is not the tip"
  [ "$(git -C "$REMOTE" show gh-pages:badges/main/unit.svg)" = "<svg>rival</svg>" ] \
    || fail "the rival's file was lost"
}

@test "a re-apply step that finds nothing left to do ends the push green" {
  BRANCH=main bash "$PUBLISH"
  load_library
  worktree_with_commit
  rival="$(rival_commit main "chore(ci): rival")"
  arm_race "$rival"
  redo() { return "$GH_PAGES_NOOP"; }
  run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -eq 0 ] || fail "a no-op re-apply failed the push: $output"
  contains "$output" "nothing left to do on the new tip" || fail "no no-op notice: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$rival" ] || fail "something was pushed on top of the rival"
}

@test "any other re-apply exit is fatal and names the code" {
  BRANCH=main bash "$PUBLISH"
  load_library
  worktree_with_commit
  rival="$(rival_commit main "chore(ci): rival")"
  arm_race "$rival"
  redo() { return 7; }
  run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -eq 1 ] || fail "a failed re-apply did not fail the push: $output"
  contains "$output" "::error::the gh-pages re-apply step failed (exit 7)" || fail "no diagnosis in: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$rival" ] || fail "something was pushed after the failure"
}

@test "gh_pages_push tries five times by default before giving up" {
  BRANCH=main bash "$PUBLISH"
  load_library
  worktree_with_commit
  reject_every_push
  redo() { echo called >> "$TMP/redo-calls"; commit_something "$1"; }
  unset GH_PAGES_PUSH_ATTEMPTS
  run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -eq 1 ] || fail "a push that is always rejected did not fail: $output"
  contains "$output" "::error::could not push gh-pages in 5 attempts" || fail "no diagnosis in: $output"
  contains "$output" "push attempt 5 of 5 was rejected" || fail "the fifth attempt is not logged: $output"
  [ "$(wc -l < "$TMP/redo-calls" | tr -d ' ')" = "5" ] \
    || fail "the re-apply step ran $(wc -l < "$TMP/redo-calls" | tr -d ' ') times, not 5"
}

# The real backoff is attempt times GH_PAGES_RETRY_DELAY seconds, 2 by default.
# `sleep` is replaced by a function that records its argument, so the schedule
# is asserted without waiting through it.
@test "the backoff grows by the retry delay with each attempt, two seconds by default" {
  BRANCH=main bash "$PUBLISH"
  load_library
  worktree_with_commit
  reject_every_push
  sleep() { printf '%s\n' "$1" >> "$TMP/sleeps"; }
  redo() { commit_something "$1"; }
  unset GH_PAGES_RETRY_DELAY
  GH_PAGES_PUSH_ATTEMPTS=3 run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -eq 1 ] || fail "a push that is always rejected did not fail: $output"
  [ "$(tr '\n' ' ' < "$TMP/sleeps")" = "2 4 6 " ] || fail "unexpected default backoff: $(cat "$TMP/sleeps")"
  rm "$TMP/sleeps"
  GH_PAGES_RETRY_DELAY=5 GH_PAGES_PUSH_ATTEMPTS=2 run gh_pages_push "$RUNNER_TEMP/gh-pages" redo
  [ "$status" -eq 1 ] || fail "a push that is always rejected did not fail: $output"
  [ "$(tr '\n' ' ' < "$TMP/sleeps")" = "5 10 " ] || fail "GH_PAGES_RETRY_DELAY was not honoured: $(cat "$TMP/sleeps")"
}
