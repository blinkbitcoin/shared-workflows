#!/usr/bin/env bash
# Re-run the failed jobs of a promotion run that the green gate blocked.
#
# build-prepare.yml's green gate (require-green-run.sh) refuses to promote a
# commit until the workflow that built it has concluded green. A promotion that
# is dispatched exactly once - release-please starts the beta promotion when it
# publishes the release, and nothing starts it again - and that arrives while
# that build is still running (or red) fails at the gate with nothing left to
# retry it. The caller runs this from a `workflow_run` listener on the build,
# once it concludes green: it finds a concluded-but-unsuccessful WORKFLOW run
# for the same commit and re-runs only its failed jobs, so nothing that already
# succeeded runs twice.
#
# The match is the build's head commit, which is the release commit. A
# promotion dispatched at the tag has that commit as its head; if another
# commit lands in between, nothing matches and this does nothing, which is
# accepted: matching more loosely risks re-running a promotion for a different
# release, and the operator can re-run it by hand. `cancelled` and `timed_out`
# count as blocked too, so a run evicted from a concurrency group is retried.
#
# Usage: retry.sh   Env: GH_TOKEN, GH_REPO (owner/name), WORKFLOW
# (the promotion's workflow file, e.g. cd-beta.yml), HEAD_SHA.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh

: "${GH_TOKEN:?GH_TOKEN not set}"
: "${GH_REPO:?GH_REPO not set}"
: "${WORKFLOW:?WORKFLOW not set}"
: "${HEAD_SHA:?HEAD_SHA not set}"

run_id="$(gh run list --workflow "$WORKFLOW" --commit "$HEAD_SHA" --limit 20 \
  --json databaseId,status,conclusion \
  --jq '[.[] | select(.status == "completed" and .conclusion != "success" and .conclusion != "skipped")][0].databaseId // empty')" ||
  die "could not list $WORKFLOW runs for $HEAD_SHA in $GH_REPO (does the job grant actions: write?)"

if [ -z "$run_id" ]; then
  log "no concluded, unsuccessful $WORKFLOW run for $HEAD_SHA - nothing to retry"
  exit 0
fi
log "re-running the failed jobs of $WORKFLOW run $run_id ($HEAD_SHA)"
gh run rerun "$run_id" --failed || die "could not re-run the failed jobs of $WORKFLOW run $run_id"
