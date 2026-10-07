#!/usr/bin/env bash
# Removes gh-pages/badges/<branch>/ when a pull request closes, so the branch
# directory does not outlive the branch. Nothing to do - no gh-pages branch yet,
# or no directory for this branch - is success, not an error: this runs on every
# closed PR, including ones whose CI never published anything.
#
# Env: BRANCH (required). CI: the badges-cleanup job of pr-closed.yml.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/gh-pages-lib.sh"
require_cmd git

require_env BRANCH
gh_pages_assert_branch "$BRANCH"

# Two steps: a command substitution used as an argument does not propagate its
# exit status, and `cd ""` is a successful no-op. This script deletes a branch
# directory and pushes, so running it in the wrong repository is the worst of
# the three places this pattern appeared.
root="$(consumer_root)"
cd "$root"
# The unit of work, re-runnable on a moved tip - see gh_pages_push. Modify/delete
# is the conflict a replayed commit can never resolve, which is why this is a
# function and not a straight line.
#
# GH_PAGES_NOOP means the directory is not there: either nothing was ever
# published for this branch, or a competing cleanup already removed it. Any
# other non-zero exit is a real failure and is fatal at the call site - a
# removal that could not be committed must not read as "already gone".
drop_badges() {
  local wt="$1"
  if [ ! -d "$wt/badges/$BRANCH" ]; then
    log "gh-pages: no badges published for $BRANCH - nothing to clean"
    return "$GH_PAGES_NOOP"
  fi
  git -C "$wt" rm -rq "badges/$BRANCH" || return 2
  git -C "$wt" commit -qm "chore(ci): drop badges for closed branch $BRANCH" || return 2
}

wt="${RUNNER_TEMP:-/tmp}/gh-pages"

# CREATE=0: creating a gh-pages branch in order to delete nothing from it would
# be a surprising side effect of closing a pull request.
wt_rc=0
CREATE=0 gh_pages_worktree "$wt" || wt_rc=$?
case "$wt_rc" in
  0) ;;
  "$GH_PAGES_ABSENT")
    log "gh-pages: no such branch - nothing to clean"
    exit 0
    ;;
  *) die "could not open the gh-pages worktree (exit $wt_rc)" ;;
esac
rc=0
drop_badges "$wt" || rc=$?
case "$rc" in
  0)
    gh_pages_push "$wt" drop_badges
    log "gh-pages: removed badges/$BRANCH"
    ;;
  "$GH_PAGES_NOOP") ;;
  *) die "could not remove badges/$BRANCH (exit $rc)" ;;
esac
