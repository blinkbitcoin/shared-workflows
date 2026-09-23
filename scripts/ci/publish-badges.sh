#!/usr/bin/env bash
# Publishes the branch's rendered badges to gh-pages/badges/<branch>/.
#
# The consumer's render script (publish-badges.yml's `render-script`, default
# `badges:render`) has already written coverage/badge/{unit,e2e,coverage}.svg
# and their .json siblings; this only moves them onto the branch GitHub serves
# through raw.githubusercontent.com. A badge the render script chose not to
# write - a skipped Unit writes no coverage badge - is simply not copied, so the
# one already published stays.
#
# Env: BRANCH (required), SHA (required), BADGE_DIR (default coverage/badge).
# CI: the Publish step of publish-badges.yml.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/gh-pages-lib.sh"
require_cmd git

: "${BRANCH:?BRANCH is required}" "${SHA:?SHA is required}"
gh_pages_assert_branch "$BRANCH"

root="$(consumer_root)"
cd "$root"
badge_dir="${BADGE_DIR:-coverage/badge}"
[ -d "$badge_dir" ] || die "no badge directory at $root/$badge_dir - did the render script run?"

badges=()
while IFS= read -r file; do badges+=("$file"); done < <(
  find "$badge_dir" -maxdepth 1 -type f \( -name '*.svg' -o -name '*.json' \) | sort
)
[ "${#badges[@]}" -gt 0 ] || die "no .svg/.json badges in $root/$badge_dir - did the render script run?"

# The unit of work, as a function rather than a straight line, because
# gh_pages_push re-runs it on the fresh tip when another job's publish beat us
# there: replaying our commit would conflict on any badge both jobs wrote.
#
# Exit codes are load-bearing. GH_PAGES_NOOP means "there is nothing to commit"
# - the badges are unchanged, or a competing commit already published these
# bytes - and is the only non-zero exit that is not a failure. Everything else
# returns 2 and is fatal at the call site: a refused commit or an unwritable
# path must not be read as "already done", because that publishes nothing,
# exits 0 and leaves the branch's badge stale with a green CI run.
apply_badges() {
  local wt="$1"
  mkdir -p "$wt/badges/$BRANCH" || return 2
  cp "${badges[@]}" "$wt/badges/$BRANCH/" || return 2
  printf '%s\n' \
    '# CI-owned branch' \
    '' \
    'badges/<branch>/{coverage,unit,e2e}.svg (+ their .json siblings) - written by' \
    'the badges job in the CI workflow (shared-workflows publish-badges.yml ->' \
    'scripts/ci/publish-badges.sh) on every run; a branch directory is removed when' \
    "its pull request closes (badges-cleanup.sh). Do not edit by hand." \
    '' \
    'This branch is NOT the GitHub Pages source. Keep the Pages source set to' \
    '"GitHub Actions": the web export deploys as a Pages artifact, and the badges' \
    'are served from raw.githubusercontent.com.' > "$wt/README.md" || return 2
  git -C "$wt" add -A badges README.md || return 2
  if git -C "$wt" diff --cached --quiet; then
    log "gh-pages: badges for $BRANCH unchanged"
    return "$GH_PAGES_NOOP"
  fi
  git -C "$wt" commit -qm "chore(ci): badges for $BRANCH @ ${SHA:0:7}" || return 2
}

wt="${RUNNER_TEMP:-/tmp}/gh-pages"
gh_pages_worktree "$wt"
# `|| rc=$?` rather than an `if`: this keeps the callback's own exit code instead
# of flattening every failure into one bit. It does NOT restore errexit inside
# the callback - `set -e` is suppressed in any non-final member of a `||` list,
# exactly as in an `if` condition - so every step in there carries its own
# `|| return 2`. A new step without one would fail silently.
rc=0
apply_badges "$wt" || rc=$?
case "$rc" in
  0)
    gh_pages_push "$wt" apply_badges
    log "gh-pages: published ${#badges[@]} file(s) to badges/$BRANCH"
    ;;
  "$GH_PAGES_NOOP") ;;
  *) die "could not stage the badges for $BRANCH (exit $rc)" ;;
esac
