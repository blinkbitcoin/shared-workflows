#!/usr/bin/env bats
# scripts/ci/badges-cleanup.sh against a throwaway bare remote: its own test.
#
# Every exit path of the script: a missing git, a missing or unsafe BRANCH, a
# consumer directory that is not there, no gh-pages branch at all (success,
# creating none), a gh-pages worktree that cannot be opened, no directory for
# this branch (success), a removal the consumer's hooks refuse, a push that
# never lands, a re-apply that fails - and the success paths: a plain removal,
# and one that loses a race to another job and re-applies onto the new tip.
#
# The branches to clean up are published with publish-badges.sh, which is only
# the fixture here; its own cases are in test/publish-badges.bats. The races are
# deterministic: `arm_race` installs a pre-receive hook on the bare remote that
# moves gh-pages to a prepared competing commit and then rejects our first push.
load test_helper

PUBLISH="$REPO_ROOT/scripts/ci/publish-badges.sh"
CLEANUP="$REPO_ROOT/scripts/ci/badges-cleanup.sh"

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

# The render script's output, stubbed: these scripts only ever copy files.
render_badges() {
  local root="$1" coverage="$2"
  mkdir -p "$root/coverage/badge"
  for name in unit e2e; do
    printf '<svg>%s</svg>\n' "$name" > "$root/coverage/badge/$name.svg"
    printf '{"label":"%s"}\n' "$name" > "$root/coverage/badge/$name.json"
  done
  printf '<svg>%s</svg>\n' "$coverage" > "$root/coverage/badge/coverage.svg"
}

# A clone of the published branch, so assertions read what the remote actually has.
gh_pages_checkout() {
  local dir="$TMP/verify-$RANDOM"
  git clone -q -b gh-pages "$REMOTE" "$dir" 2>/dev/null || return 1
  echo "$dir"
}

remote_has_gh_pages() {
  git -C "$REMOTE" rev-parse --verify -q refs/heads/gh-pages >/dev/null
}

# rival_commit BRANCH SUBJECT [EXTRA] - build, but do NOT push, a commit on
# gh-pages that another job would have made: it rewrites badges/BRANCH/unit.svg
# (a path inside the directory the cleanup removes, so a replayed commit is
# guaranteed to conflict) and optionally adds EXTRA beside it. Prints its sha.
rival_commit() {
  local branch="$1" subject="$2" extra="${3:-}" dir="$TMP/rival-$RANDOM"
  git clone -q -b gh-pages "$REMOTE" "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  mkdir -p "$dir/badges/$branch"
  echo "<svg>rival</svg>" > "$dir/badges/$branch/unit.svg"
  [ -z "$extra" ] || echo "<svg>extra</svg>" > "$dir/badges/$branch/$extra"
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

# The second conflicting race, and the easier one to hit in practice: closing a
# pull request while its CI is still publishing. Modify/delete, which no merge
# strategy resolves - `-X theirs` included. The closed branch's directory is
# meant to be gone afterwards, so the cleanup is the last writer.
@test "a PR-close cleanup racing a late publish for that branch converges" {
  BRANCH=feat/x bash "$PUBLISH"
  BRANCH=main bash "$PUBLISH"
  rival="$(rival_commit feat/x "chore(ci): late badges for feat/x")"
  arm_race "$rival"
  BRANCH=feat/x run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "the cleanup race never converged: $output"
  out="$(gh_pages_checkout)"
  [ ! -d "$out/badges/feat/x" ] || fail "the closed branch's badges came back"
  [ -f "$out/badges/main/unit.svg" ] || fail "the cleanup took another branch's badges"
}

# The other end of the same restructure: when the fresh tip already has the work
# done, re-applying finds nothing to do and the run ends green rather than
# pushing an empty commit or burning the whole retry budget.
@test "a cleanup whose work another job already did ends green without pushing" {
  BRANCH=feat/x bash "$PUBLISH"
  BRANCH=main bash "$PUBLISH"
  # The competing commit is the same cleanup, done first.
  dir="$TMP/rival-cleanup"
  git clone -q -b gh-pages "$REMOTE" "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  git -C "$dir" rm -rq "badges/feat/x"
  git -C "$dir" commit -qm "chore(ci): drop badges for closed branch feat/x"
  git -C "$dir" push -q origin "HEAD:refs/rivals/cleanup"
  arm_race "$(git -C "$dir" rev-parse HEAD)"
  BRANCH=feat/x run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed after losing the race: $output"
  contains "$output" "nothing left to do" || fail "expected the no-op notice: $output"
  out="$(gh_pages_checkout)"
  [ ! -d "$out/badges/feat/x" ]
  [ "$(git -C "$out" log -1 --pretty=%s)" = "chore(ci): drop badges for closed branch feat/x" ] \
    || fail "an empty commit was pushed on top: $(git -C "$out" log -1 --pretty=%s)"
}

@test "cleanup with no gh-pages branch is a no-op, and creates none" {
  BRANCH=feat/gone run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed: $output"
  contains "$output" "nothing to clean" || fail "unexpected output: $output"
  ! remote_has_gh_pages || fail "cleanup created a gh-pages branch"
}

@test "cleanup with no directory for this branch is a no-op" {
  BRANCH=main bash "$PUBLISH"
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  BRANCH=feat/never-published run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed: $output"
  contains "$output" "nothing to clean" || fail "unexpected output: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ]
}

@test "cleanup removes only the closed branch's directory" {
  BRANCH=main bash "$PUBLISH"
  BRANCH=feat/two bash "$PUBLISH"
  BRANCH=feat/two run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed: $output"
  out="$(gh_pages_checkout)"
  [ ! -d "$out/badges/feat/two" ] || fail "the closed branch's badges are still there"
  [ -f "$out/badges/main/unit.svg" ] || fail "cleanup took another branch's badges"
  contains "$(git -C "$out" log -1 --pretty=%s)" "drop badges for closed branch feat/two" \
    || fail "unexpected commit subject: $(git -C "$out" log -1 --pretty=%s)"
}

@test "cleanup refuses an unsafe branch name" {
  BRANCH=main bash "$PUBLISH"
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  BRANCH="../main" run bash "$CLEANUP"
  [ "$status" -ne 0 ] || fail "cleanup accepted '../main'"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ]
}

@test "the two no-op paths say which of them it was" {
  BRANCH=feat/gone run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed: $output"
  contains "$output" "no such branch - nothing to clean" || fail "the missing branch is not named: $output"
  BRANCH=main bash "$PUBLISH"
  BRANCH=feat/gone run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed: $output"
  contains "$output" "no badges published for feat/gone - nothing to clean" \
    || fail "the missing directory is not named: $output"
}

@test "a successful cleanup logs the directory it removed" {
  BRANCH=feat/two bash "$PUBLISH"
  BRANCH=feat/two run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed: $output"
  contains "$output" "removed badges/feat/two" || fail "the removal is not logged: $output"
}

@test "cleanup leaves the consumer checkout on its own branch" {
  BRANCH=feat/two bash "$PUBLISH"
  BRANCH=feat/two run bash "$CLEANUP"
  [ "$status" -eq 0 ] || fail "cleanup failed: $output"
  [ "$(git -C "$CONSUMER" rev-parse --abbrev-ref HEAD)" = "main" ] \
    || fail "the consumer checkout was moved off its branch"
  [ -f "$CONSUMER/app.txt" ] || fail "the consumer's source tree was touched"
}

@test "cleanup fails when git is not installed" {
  nogit="$TMP/no-git"
  mkdir -p "$nogit"
  ln -s "$(command -v dirname)" "$nogit/dirname"
  run env PATH="$nogit" BRANCH=feat/x "$BASH" "$CLEANUP"
  [ "$status" -eq 1 ] || fail "cleanup ran without git: $output"
  contains "$output" "missing command: git" || fail "unexpected error: $output"
}

@test "cleanup requires BRANCH, and an empty one counts as missing" {
  run env -u BRANCH bash "$CLEANUP"
  [ "$status" -ne 0 ] || fail "cleanup ran without BRANCH: $output"
  contains "$output" "BRANCH is required" || fail "unexpected error: $output"
  BRANCH="" run bash "$CLEANUP"
  [ "$status" -ne 0 ] || fail "cleanup ran with an empty BRANCH: $output"
  contains "$output" "BRANCH is required" || fail "unexpected error: $output"
}

@test "cleanup gives each refused branch name its own diagnosis" {
  BRANCH=main bash "$PUBLISH"
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  BRANCH="../main" run bash "$CLEANUP"
  [ "$status" -eq 1 ] || fail "cleanup accepted '../main': $output"
  contains "$output" "refusing to use branch name '../main' as a gh-pages path" \
    || fail "unexpected error: $output"
  BRANCH="main badges" run bash "$CLEANUP"
  [ "$status" -eq 1 ] || fail "cleanup accepted 'main badges': $output"
  contains "$output" "has characters that cannot be a gh-pages path" || fail "unexpected error: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ] || fail "a refused name still moved gh-pages"
}

@test "cleanup fails when the consumer directory does not exist" {
  BRANCH=main bash "$PUBLISH"
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  BRANCH=main GITHUB_WORKSPACE="$TMP/missing" run bash "$CLEANUP"
  [ "$status" -ne 0 ] || fail "cleanup ran against a missing workspace: $output"
  contains "$output" "$TMP/missing" || fail "the error does not name the missing directory: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ] || fail "gh-pages moved anyway"
}

# The worktree is opened inside a `||` list, where errexit does not reach, so a
# git failure there comes back as a status. It must not be read as "no such
# branch": that would exit green with the closed branch's badges still up.
# RUNNER_TEMP pointing at a regular file is the simplest way to make the
# worktree impossible to create while gh-pages exists on the remote.
@test "a gh-pages worktree that cannot be opened fails loudly, not as nothing to clean" {
  BRANCH=feat/x bash "$PUBLISH"
  : > "$TMP/not-a-directory"
  BRANCH=feat/x RUNNER_TEMP="$TMP/not-a-directory" run bash "$CLEANUP"
  [ "$status" -eq 1 ] || fail "cleanup did not fail without a worktree: $output"
  contains "$output" "::error::could not open the gh-pages worktree (exit" \
    || fail "no diagnosis in: $output"
  not_contains "$output" "nothing to clean" || fail "the failure was reported as a no-op: $output"
  out="$(gh_pages_checkout)" || fail "gh-pages disappeared from the remote"
  [ -d "$out/badges/feat/x" ] || fail "the badges were removed without a worktree"
}

@test "a removal the consumer's hooks refuse fails loudly" {
  BRANCH=feat/x bash "$PUBLISH"
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  cat > "$CONSUMER/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
echo "refusing" >&2
exit 1
HOOK
  chmod +x "$CONSUMER/.git/hooks/pre-commit"
  BRANCH=feat/x run bash "$CLEANUP"
  [ "$status" -eq 1 ] || fail "a refused removal reported success: $output"
  contains "$output" "::error::could not remove badges/feat/x (exit 2)" || fail "no diagnosis in: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ] || fail "the branch moved anyway"
}

@test "a cleanup the remote keeps rejecting fails instead of reporting success" {
  BRANCH=feat/x bash "$PUBLISH"
  cat > "$REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
cat >/dev/null
exit 1
HOOK
  chmod +x "$REMOTE/hooks/pre-receive"
  BRANCH=feat/x GH_PAGES_PUSH_ATTEMPTS=2 run bash "$CLEANUP"
  [ "$status" -eq 1 ] || fail "a rejected cleanup reported success: $output"
  contains "$output" "could not push gh-pages in 2 attempts" || fail "no diagnosis in: $output"
  not_contains "$output" "removed badges/feat/x" || fail "the removal was logged although it never landed"
  out="$(gh_pages_checkout)" || fail "gh-pages disappeared from the remote"
  [ -d "$out/badges/feat/x" ] || fail "the remote lost the directory although every push was rejected"
}

# The race again, but the re-apply's own commit is refused: that must die, not
# be read as "the competing commit already removed it".
@test "a cleanup whose re-apply fails is fatal, not mistaken for nothing left to do" {
  BRANCH=feat/x bash "$PUBLISH"
  rival="$(rival_commit feat/x "chore(ci): late badges for feat/x")"
  arm_race "$rival"
  # Refuses every commit except the first, so the initial removal gets through
  # and only the re-apply on the new tip is rejected.
  cat > "$CONSUMER/.git/hooks/pre-commit" <<HOOK
#!/bin/sh
[ -f "$TMP/commit-seen" ] && { echo "refusing" >&2; exit 1; }
: > "$TMP/commit-seen"
exit 0
HOOK
  chmod +x "$CONSUMER/.git/hooks/pre-commit"
  BRANCH=feat/x run bash "$CLEANUP"
  [ "$status" -eq 1 ] || fail "a failed re-apply reported success: $output"
  contains "$output" "the gh-pages re-apply step failed (exit 2)" || fail "no diagnosis in: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$rival" ] || fail "gh-pages moved past the rival anyway"
}
