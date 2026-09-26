#!/usr/bin/env bats
# scripts/ci/publish-badges.sh against a throwaway bare remote: its own test.
#
# Every exit path of the script: a missing git, a missing BRANCH or SHA, a
# branch name that cannot be a path, a consumer directory that is not there, no
# rendered badges, a gh-pages worktree that cannot be created, a commit the
# consumer's hooks refuse, a push that never lands - and the success paths: the
# first publish (an orphan), a later one, an unchanged one, and one that loses a
# race to another job's publish and re-applies onto the new tip.
#
# The races are deterministic, not timing-dependent: `arm_race` installs a
# pre-receive hook on the bare remote that moves gh-pages to a prepared
# competing commit and then rejects our first push, which is exactly the state
# a real concurrent publish leaves us in. The library under it has its own
# file, test/gh-pages-lib.bats; the removal on pull request close is
# test/badges-cleanup.bats.
load test_helper

PUBLISH="$REPO_ROOT/scripts/ci/publish-badges.sh"

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
# (the path our own publish touches, so a replayed commit is guaranteed to
# conflict) and optionally adds EXTRA beside it. Prints its sha.
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

@test "the first publish creates gh-pages as an orphan carrying only badges" {
  ! remote_has_gh_pages || fail "the remote already has a gh-pages branch"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)" || fail "no gh-pages branch on the remote after publishing"
  [ -f "$out/badges/main/unit.svg" ] || fail "no unit badge: $(find "$out" -type f)"
  [ -f "$out/badges/main/coverage.svg" ]
  [ -f "$out/badges/main/e2e.json" ]
  [ -f "$out/README.md" ]
  # The orphan must not carry the consumer's source tree with it.
  [ ! -e "$out/app.txt" ] || fail "gh-pages carries the consumer's source tree"
  # A true orphan: no parent, so gh-pages shares no history with main.
  parents="$(git -C "$out" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')"
  [ "$parents" = "1" ] || fail "the first gh-pages commit has a parent"
  contains "$(git -C "$out" log -1 --pretty=%s)" "chore(ci): badges for main @ 0123456" \
    || fail "unexpected commit subject: $(git -C "$out" log -1 --pretty=%s)"
}

@test "the consumer checkout is left on its own branch, untouched" {
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  [ "$(git -C "$CONSUMER" rev-parse --abbrev-ref HEAD)" = "main" ]
  [ -z "$(git -C "$CONSUMER" status --porcelain -- app.txt)" ]
}

@test "a second publish on another branch keeps the first branch's badges" {
  BRANCH=main bash "$PUBLISH"
  render_badges "$CONSUMER" 91%
  BRANCH=feat/two run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "second publish failed: $output"
  out="$(gh_pages_checkout)"
  [ -f "$out/badges/main/unit.svg" ] || fail "the first branch's badges were lost"
  contains "$(cat "$out/badges/feat/two/coverage.svg")" "91%" \
    || fail "the second branch's coverage badge is not the one just rendered"
  [ "$(git -C "$out" rev-list --count HEAD)" = "2" ]
}

@test "publishing identical badges again commits nothing" {
  BRANCH=main bash "$PUBLISH"
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  contains "$output" "unchanged" || fail "expected an 'unchanged' notice: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ] \
    || fail "an unchanged publish still moved the branch"
}

# The easy half: the competing commit touches another branch's directory, so
# even a replayed commit would have applied. Kept, and renamed to say so - it
# used to be the only concurrency case here and its name claimed the hard one.
@test "a concurrent publish for another branch survives our retry" {
  BRANCH=main bash "$PUBLISH"
  rival="$(rival_commit other "chore(ci): badges for other")"
  arm_race "$rival"
  render_badges "$CONSUMER" 77%
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish never converged: $output"
  contains "$output" "re-applying" || fail "expected the retry notice: $output"
  out="$(gh_pages_checkout)"
  [ -f "$out/badges/other/unit.svg" ] || fail "the concurrent publish was clobbered"
  contains "$(cat "$out/badges/main/coverage.svg")" "77%" || fail "our own badge did not land"
}

# The hard half, and the one the old suite missed: the competing commit rewrote
# the very file we are writing. A replayed commit conflicts on content and can
# never converge, however many times it is retried; re-applying the copy onto
# the fresh tip does, and leaves the newer render in place.
@test "two publishes racing on the same branch converge, and the newer render wins" {
  BRANCH=main bash "$PUBLISH"
  rival="$(rival_commit main "chore(ci): badges for main (rival)" rival.svg)"
  arm_race "$rival"
  render_badges "$CONSUMER" 77%
  echo "<svg>ours</svg>" > "$CONSUMER/coverage/badge/unit.svg"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "the same-branch race never converged: $output"
  contains "$output" "re-applying" || fail "expected the retry notice: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/unit.svg")" "ours" \
    || fail "the rival's badge survived our publish: $(cat "$out/badges/main/unit.svg")"
  contains "$(cat "$out/badges/main/coverage.svg")" "77%" || fail "our coverage badge did not land"
  # Last writer wins per file, but nothing the rival wrote is thrown away.
  [ -f "$out/badges/main/rival.svg" ] || fail "the rival's other file was lost"
  contains "$(git -C "$out" log --oneline)" "rival" || fail "the rival commit was dropped from history"
}

# The orphan path creates a local gh-pages branch. Nothing on the remote
# changes when the push then fails, so the next run takes the orphan path again
# - and used to die with "a branch named 'gh-pages' already exists", every time,
# until someone created the branch by hand. Sticky, and invisible on a fresh
# hosted runner: it needs a reused workspace, which is exactly what the
# linux-runner input allows.
@test "a failed publish does not poison the next publish in the same checkout" {
  cat > "$REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
cat >/dev/null
exit 1
HOOK
  chmod +x "$REMOTE/hooks/pre-receive"
  BRANCH=main GH_PAGES_PUSH_ATTEMPTS=1 run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "the publish reported success against a rejecting remote"
  rm "$REMOTE/hooks/pre-receive"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "the next publish in the same checkout failed: $output"
  not_contains "$output" "already exists" \
    || fail "the stale local gh-pages branch is still there: $output"
  out="$(gh_pages_checkout)"
  [ -f "$out/badges/main/unit.svg" ] || fail "the recovered publish wrote nothing"
}

# "Nothing to do" and "the commit failed" must not be the same signal. A linked
# worktree shares $GIT_COMMON_DIR/hooks with the checkout it hangs off, so any
# pre-commit hook in the consumer's clone applies to the gh-pages worktree too -
# the most realistic way for the commit inside the callback to fail. Reporting
# success here would leave the branch's badge silently stale while CI stayed
# green, which is the exact class this file exists to rule out.
@test "a commit the consumer's hooks refuse fails loudly, not silently" {
  BRANCH=main bash "$PUBLISH"
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  cat > "$CONSUMER/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
echo "refusing" >&2
exit 1
HOOK
  chmod +x "$CONSUMER/.git/hooks/pre-commit"
  render_badges "$CONSUMER" 77%
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publishing nothing reported success: $output"
  contains "$output" "could not stage the badges" || fail "no diagnosis in: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ] || fail "the branch moved anyway"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/coverage.svg")" "100%" \
    || fail "the stale badge is not the one still published"
}

# The same distinction inside the retry: the first commit succeeds, the push is
# rejected, and the re-apply's commit then fails. That must die, not be read as
# "the competing commit already did it".
@test "a re-apply that fails is fatal, not mistaken for nothing left to do" {
  BRANCH=main bash "$PUBLISH"
  rival="$(rival_commit main "chore(ci): badges for main (rival)")"
  arm_race "$rival"
  # Refuses every commit except the first, so the initial apply gets through and
  # only the re-apply on the new tip is rejected.
  cat > "$CONSUMER/.git/hooks/pre-commit" <<HOOK
#!/bin/sh
[ -f "$TMP/commit-seen" ] && { echo "refusing" >&2; exit 1; }
: > "$TMP/commit-seen"
exit 0
HOOK
  chmod +x "$CONSUMER/.git/hooks/pre-commit"
  render_badges "$CONSUMER" 77%
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "a failed re-apply reported success: $output"
  contains "$output" "re-apply step failed" || fail "no diagnosis in: $output"
}

@test "publish refuses a branch name that is not a safe path segment" {
  for bad in "../../etc" "a b" "" "/abs" "x/../y"; do
    BRANCH="$bad" run bash "$PUBLISH"
    [ "$status" -ne 0 ] || fail "publish accepted branch name '$bad'"
  done
  ! remote_has_gh_pages || fail "a rejected branch name still touched gh-pages"
}

@test "publish fails when the render script wrote nothing" {
  rm -rf "$CONSUMER/coverage/badge"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publish succeeded with no badges: $output"
  contains "$output" "render script" || fail "unhelpful message: $output"
  mkdir -p "$CONSUMER/coverage/badge"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publish succeeded with an empty badge directory"
}

@test "a skipped coverage badge leaves the published one alone" {
  BRANCH=main bash "$PUBLISH"
  # The render script writes no coverage.svg when Unit was skipped.
  rm "$CONSUMER/coverage/badge/coverage.svg"
  echo '<svg>unit2</svg>' > "$CONSUMER/coverage/badge/unit.svg"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/coverage.svg")" "100%" \
    || fail "the published coverage badge was blanked by a run that rendered none"
  contains "$(cat "$out/badges/main/unit.svg")" "unit2" || fail "the new unit badge did not land"
}

@test "publishing twice in one job works (the worktree is reused, not stacked)" {
  BRANCH=main bash "$PUBLISH"
  render_badges "$CONSUMER" 88%
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "the second publish in the same job failed: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/coverage.svg")" "88%" || fail "the second publish did not land"
}

@test "a publish logs how many files it published and writes the CI-owned README" {
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  contains "$output" "published 5 file(s) to badges/main" || fail "no count in the log: $output"
  out="$(gh_pages_checkout)" || fail "no gh-pages branch on the remote after publishing"
  contains "$(cat "$out/README.md")" "# CI-owned branch" || fail "the README does not say who owns the branch"
  contains "$(cat "$out/README.md")" "NOT the GitHub Pages source" \
    || fail "the README does not warn against making the branch the Pages source"
}

@test "publish copies only the .svg and .json files at the top of the badge directory" {
  echo "notes" > "$CONSUMER/coverage/badge/notes.txt"
  mkdir -p "$CONSUMER/coverage/badge/nested"
  echo "<svg>nested</svg>" > "$CONSUMER/coverage/badge/nested/deep.svg"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)" || fail "no gh-pages branch on the remote after publishing"
  [ ! -e "$out/badges/main/notes.txt" ] || fail "a file that is not a badge was published"
  [ ! -e "$out/badges/main/nested" ] || fail "a nested directory was published"
  [ ! -e "$out/badges/main/deep.svg" ] || fail "a nested badge was published"
  [ -f "$out/badges/main/unit.json" ] || fail "the .json badge data was not published"
}

@test "publish reads the badges from BADGE_DIR when it is set" {
  mkdir -p "$CONSUMER/build"
  mv "$CONSUMER/coverage/badge" "$CONSUMER/build/badges"
  BRANCH=main BADGE_DIR=build/badges run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish from BADGE_DIR failed: $output"
  out="$(gh_pages_checkout)" || fail "no gh-pages branch on the remote after publishing"
  contains "$(cat "$out/badges/main/coverage.svg")" "100%" || fail "the badges in BADGE_DIR were not published"
}

@test "publish names the missing BADGE_DIR in its error" {
  BRANCH=main BADGE_DIR=build/nowhere run bash "$PUBLISH"
  [ "$status" -eq 1 ] || fail "publish did not fail on a missing BADGE_DIR: $output"
  contains "$output" "::error::no badge directory at" || fail "no error annotation: $output"
  contains "$output" "build/nowhere" || fail "the error does not name the directory: $output"
  ! remote_has_gh_pages || fail "a publish with no badges still created gh-pages"
}

@test "publish names the badge directory when it holds no badges" {
  rm -f "$CONSUMER"/coverage/badge/*
  echo "notes" > "$CONSUMER/coverage/badge/notes.txt"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 1 ] || fail "publish did not fail on a directory without badges: $output"
  contains "$output" "no .svg/.json badges in" || fail "unexpected error: $output"
}

@test "publish works from a WORKING_DIRECTORY inside the workspace" {
  mkdir -p "$CONSUMER/app"
  mv "$CONSUMER/coverage" "$CONSUMER/app/coverage"
  BRANCH=main WORKING_DIRECTORY=app run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish from a working directory failed: $output"
  out="$(gh_pages_checkout)" || fail "no gh-pages branch on the remote after publishing"
  [ -f "$out/badges/main/unit.svg" ] || fail "the working directory's badges were not published"
  [ ! -e "$out/app" ] || fail "the working directory leaked into the gh-pages layout"
}

@test "publish fails when git is not installed" {
  nogit="$TMP/no-git"
  mkdir -p "$nogit"
  ln -s "$(command -v dirname)" "$nogit/dirname"
  run env PATH="$nogit" BRANCH=main "$BASH" "$PUBLISH"
  [ "$status" -eq 1 ] || fail "publish ran without git: $output"
  contains "$output" "missing command: git" || fail "unexpected error: $output"
}

@test "publish requires BRANCH" {
  run env -u BRANCH bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publish ran without BRANCH: $output"
  contains "$output" "BRANCH is required" || fail "unexpected error: $output"
  ! remote_has_gh_pages || fail "a publish without BRANCH still created gh-pages"
}

@test "publish requires SHA" {
  run env -u SHA BRANCH=main bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publish ran without SHA: $output"
  contains "$output" "SHA is required" || fail "unexpected error: $output"
  ! remote_has_gh_pages || fail "a publish without SHA still created gh-pages"
}

@test "publish gives each refused branch name its own diagnosis" {
  BRANCH="../x" run bash "$PUBLISH"
  [ "$status" -eq 1 ] || fail "publish accepted '../x': $output"
  contains "$output" "refusing to use branch name '../x' as a gh-pages path" || fail "unexpected error: $output"
  BRANCH="a b" run bash "$PUBLISH"
  [ "$status" -eq 1 ] || fail "publish accepted 'a b': $output"
  contains "$output" "has characters that cannot be a gh-pages path" || fail "unexpected error: $output"
  BRANCH="" run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publish accepted an empty branch name: $output"
  contains "$output" "BRANCH is required" || fail "unexpected error: $output"
}

@test "publish fails when the consumer directory does not exist" {
  BRANCH=main GITHUB_WORKSPACE="$TMP/missing" run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publish ran against a missing workspace: $output"
  contains "$output" "$TMP/missing" || fail "the error does not name the missing directory: $output"
  ! remote_has_gh_pages || fail "a publish from a missing workspace still created gh-pages"
}

# RUNNER_TEMP pointing at a regular file makes the worktree path impossible to
# create, the simplest stand-in for a runner whose temporary directory is
# unusable. The script must stop there rather than publish from somewhere else.
@test "publish fails when the gh-pages worktree cannot be created" {
  : > "$TMP/not-a-directory"
  BRANCH=main RUNNER_TEMP="$TMP/not-a-directory" run bash "$PUBLISH"
  [ "$status" -ne 0 ] || fail "publish succeeded without a worktree: $output"
  ! remote_has_gh_pages || fail "a publish without a worktree still created gh-pages"
  [ "$(git -C "$CONSUMER" rev-parse --abbrev-ref HEAD)" = "main" ] \
    || fail "the consumer checkout was moved off its branch"
}

# The copy's own steps each carry `|| return 2`; a branch path that is a file on
# gh-pages makes the first of them, the mkdir, fail for real.
@test "a badge directory that cannot be created on gh-pages fails loudly" {
  BRANCH=main bash "$PUBLISH"
  dir="$TMP/file-in-the-way"
  git clone -q -b gh-pages "$REMOTE" "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  git -C "$dir" rm -rq badges/main
  mkdir -p "$dir/badges"
  echo "not a directory" > "$dir/badges/main"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "chore(ci): a file where the branch directory goes"
  git -C "$dir" push -q origin gh-pages
  before="$(git -C "$REMOTE" rev-parse gh-pages)"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 1 ] || fail "publish succeeded without a badge directory: $output"
  contains "$output" "::error::could not stage the badges for main (exit 2)" || fail "no diagnosis in: $output"
  [ "$(git -C "$REMOTE" rev-parse gh-pages)" = "$before" ] || fail "the branch moved anyway"
}
