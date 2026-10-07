#!/usr/bin/env bash
# Start the caller's follow-on workflows at a release tag that was just cut.
#
# Everything release-please creates - the tag, the release - is created with
# GITHUB_TOKEN, and GitHub starts no workflow from an event that token caused,
# so nothing listening for `release: published` would run. workflow_dispatch
# is the one exemption, so each follow-on is started here by name, at the tag:
# `--ref TAG` puts the run on the release commit, so its github.sha is the
# commit the release was built from.
#
# DISPATCHES is one dispatch per line, `workflow.yml key=value ...`; `{tag}` in
# a value is replaced by the tag. Blank lines and lines starting with `#` are
# skipped, so a consumer's own comment markers can sit in the list. A line that
# names no .yml/.yaml file, or carries a field that is not key=value, fails
# before anything is dispatched: half a release chain started is worse than
# none. A dispatch that fails fails the step once the rest have been tried.
#
# Usage: dispatch-at-tag.sh   Env: TAG, DISPATCHES, GH_TOKEN, GH_REPO.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh

require_env TAG GH_REPO:owner/name

lines=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  case "$line" in '#'*) continue ;; esac
  read -r -a words <<<"$line"
  case "${words[0]}" in
    *.yml | *.yaml) ;;
    *) die "not a workflow file: '${words[0]}' in dispatch line '$line'" ;;
  esac
  for field in "${words[@]:1}"; do
    [[ "$field" =~ ^[A-Za-z0-9_-]+=.*$ ]] || die "not key=value: '$field' in dispatch line '$line'"
  done
  lines+=("$line")
done <<<"${DISPATCHES:-}"
[ "${#lines[@]}" -gt 0 ] || die "DISPATCHES names no workflow to start at $TAG"

rc=0
for line in "${lines[@]}"; do
  read -r -a words <<<"$line"
  args=(workflow run "${words[0]}" --repo "$GH_REPO" --ref "$TAG")
  for field in "${words[@]:1}"; do
    args+=(-f "${field//\{tag\}/$TAG}")
  done
  log "dispatching ${words[0]} at $TAG"
  gh "${args[@]}" || { rc=1; log "could not dispatch ${words[0]} at $TAG (does the job grant actions: write?)"; }
done
[ "$rc" -eq 0 ] || die "one or more follow-on workflows were not started at $TAG"
