#!/usr/bin/env bash
# Start self-ci.yml on every release PR's branch, by name.
#
# release-please opens its PR(s) with GITHUB_TOKEN, and GitHub creates a
# pull_request run for each PR but never gives it a job - it is marked failed
# the moment the PR merges. workflow_dispatch is the one event GitHub still
# fires for work done with that token, so this is how each PR gets a CI run
# that actually executes. The red run stays beside it until the release PR
# is opened by the RELEASE_TAGGER App instead (self-release.yml).
#
# release-please-config.json sets separate-pull-requests: true across two
# packages (root shared-workflows, packages/dev-config), so one push can open
# two release PRs in the same run. The action's singular `pr` output is only
# prs[0]; the `prs` output is the JSON array of every PR the run created or
# updated, so that is what this script reads and loops over.
#
# The branch is read here, in the shell, not with fromJSON() in the step's
# `env:`: the runner validates a step's env expressions even when its `if` is
# false, and fromJSON('') is a template error (it failed the template's
# release job on its first no-PR push).
#
# Usage: dispatch-release-pr-ci.sh
# Env: PRS_JSON (release-please's `prs` output), GH_TOKEN, GH_REPO
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh jq
: "${GH_REPO:?GH_REPO not set (owner/name)}"

[ -n "${PRS_JSON:-}" ] || die "PRS_JSON is empty: release-please reported PRs but passed no prs output"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$PRS_JSON" \
  || die "PRS_JSON is not a JSON array: $PRS_JSON"
[ "$(jq 'length' <<<"$PRS_JSON")" -gt 0 ] \
  || die "PRS_JSON's prs output is an empty array"
jq -e 'all(.[]; (.headBranchName // "") != "")' >/dev/null 2>&1 <<<"$PRS_JSON" \
  || die "an element of PRS_JSON has no headBranchName: $(jq -c '.[] | select((.headBranchName // "") == "")' <<<"$PRS_JSON")"

rc=0
while IFS= read -r branch; do
  log "dispatching self-ci.yml on $branch"
  gh workflow run self-ci.yml --repo "$GH_REPO" --ref "$branch" \
    || { rc=1; log "could not dispatch self-ci.yml on $branch (does the job grant actions: write?)"; }
done < <(jq -r '.[].headBranchName // empty' <<<"$PRS_JSON")
[ "$rc" -eq 0 ] || die "one or more release PRs got no CI dispatch"
