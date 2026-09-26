#!/usr/bin/env bats
# gh-pages-lib.sh, publish-badges.sh and badges-cleanup.sh against a throwaway
# bare remote. This is the one place in the repo where a bug rewrites a branch
# instead of failing a check, so both risky paths are exercised for real: the
# orphan created when gh-pages does not exist yet, and the push-retry when
# another job's publish lands between our fetch and our push.
#
# The races are deterministic, not timing-dependent: `arm_race` installs a
# pre-receive hook on the bare remote that moves gh-pages to a prepared
# competing commit and then rejects our first push, which is exactly the state
# a real concurrent publish leaves us in. Anything less than a genuinely
# conflicting path (two publishes for the SAME branch, or a cleanup against a
# late publish for that branch) tests the easy half only - the case that cannot
# conflict - and that is what this file used to do.
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
# (the path our own publish and cleanup both touch, so a replayed commit is
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

@test "publishing twice in one job works (the worktree is reused, not stacked)" {
  BRANCH=main bash "$PUBLISH"
  render_badges "$CONSUMER" 88%
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "the second publish in the same job failed: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/coverage.svg")" "88%" || fail "the second publish did not land"
}

@test "a skipped suite leaves its published status badge alone" {
  BRANCH=main bash "$PUBLISH"
  # A render script handed `skipped` draws a grey badge; it must not land.
  echo '<svg>unit skipped</svg>' > "$CONSUMER/coverage/badge/unit.svg"
  echo '<svg>e2e2</svg>' > "$CONSUMER/coverage/badge/e2e.svg"
  BRANCH=main BADGE_UNIT=skipped BADGE_E2E=success run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/unit.svg")" "<svg>unit</svg>" \
    || fail "a skipped Unit overwrote the published unit badge: $(cat "$out/badges/main/unit.svg")"
  contains "$(cat "$out/badges/main/e2e.svg")" "e2e2" || fail "the E2E badge that did run did not land"
}

@test "a skipped E2E leaves its published status badge alone" {
  BRANCH=main bash "$PUBLISH"
  echo '<svg>e2e skipped</svg>' > "$CONSUMER/coverage/badge/e2e.svg"
  BRANCH=main BADGE_UNIT=success BADGE_E2E=skipped run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/e2e.svg")" "<svg>e2e</svg>" \
    || fail "a skipped E2E overwrote the published e2e badge"
}

@test "when every rendered badge belongs to a skipped suite, publish changes nothing" {
  BRANCH=main bash "$PUBLISH"
  before="$(git --git-dir="$REMOTE" rev-parse gh-pages)"
  rm "$CONSUMER/coverage/badge/coverage.svg"
  echo '<svg>grey</svg>' > "$CONSUMER/coverage/badge/unit.svg"
  BRANCH=main BADGE_UNIT=skipped BADGE_E2E=skipped run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  contains "$output" "skipped suite" || fail "no log line saying why nothing was published: $output"
  [ "$(git --git-dir="$REMOTE" rev-parse gh-pages)" = "$before" ] || fail "gh-pages moved"
}
