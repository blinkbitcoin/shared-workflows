#!/usr/bin/env bash
# Cancel any other queued/in-progress workflow run for the same commit, so a
# force-push doesn't leave stale runs racing the latest push. A failure to
# cancel one run (e.g. it finished in the gap between listing and cancelling)
# must not abort the whole script under `set -e`, and every page of results
# must be walked, not just the first.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh

: "${GH_TOKEN:?GH_TOKEN not set}"
: "${REPO:?REPO not set}"
: "${HEAD_SHA:?HEAD_SHA not set}"
self="${GITHUB_RUN_ID:-0}"
cancelled=0

for status in queued in_progress; do
  # Listed first, then looped over: a listing fed through `< <(...)` fails
  # unseen, and a token that cannot read the runs then reported
  # "cancelled 0 run(s)" and passed while the stale runs kept going.
  runs="$(gh api --paginate "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&status=$status&per_page=100" \
    --jq ".workflow_runs[] | select(.id != $self) | \"\(.id) \(.name)\"")" ||
    die "could not list $status runs for $HEAD_SHA in $REPO (does the job grant actions: write?)"
  while IFS=' ' read -r id name; do
    [ -n "$id" ] || continue
    log "cancelling run $id ($name)"
    if gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null 2>&1; then
      cancelled=$((cancelled + 1))
    else
      log "could not cancel run $id (already finished?)"
    fi
  done <<< "$runs"
done

log "cancelled $cancelled run(s)"
