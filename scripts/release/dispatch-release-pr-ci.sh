#!/usr/bin/env bash
# Start the caller's CI workflow (CI_WORKFLOW) on every release PR's branch,
# by name.
#
# release-please opens its PR(s) with GITHUB_TOKEN, and GitHub creates a
# pull_request run for each PR but never gives it a job - it is marked failed
# the moment the PR merges. workflow_dispatch is the one event GitHub still
# fires for work done with that token, so this is how each PR gets a CI run
# that actually executes. The red run stays beside it until the release PR
# is opened by the RELEASE_TAGGER App instead (pr-release.yml's optional
# secrets).
#
# With separate-pull-requests (this repository's own config: the root package
# and packages/app-tooling), one push can open a release PR per package. The
# action's singular `pr` output is only prs[0]; the `prs` output is the JSON
# array of every PR the run created or updated, so that is what this reads and
# loops over.
#
# The branch is read here, in the shell, not with fromJSON() in the step's
# `env:`: the runner validates a step's env expressions even when its `if` is
# false, and fromJSON('') is a template error (it failed the template's
# release job on its first no-PR push).
#
# Usage: dispatch-release-pr-ci.sh
# Env: PRS_JSON (release-please's `prs` output), CI_WORKFLOW (e.g. ci.yml),
#      GH_TOKEN, GH_REPO
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh jq
: "${GH_REPO:?GH_REPO not set (owner/name)}"
: "${CI_WORKFLOW:?CI_WORKFLOW not set (the CI workflow file to start, e.g. ci.yml)}"

[ -n "${PRS_JSON:-}" ] || die "PRS_JSON is empty: release-please reported PRs but passed no prs output"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$PRS_JSON" \
  || die "PRS_JSON is not a JSON array: $PRS_JSON"
[ "$(jq 'length' <<<"$PRS_JSON")" -gt 0 ] \
  || die "PRS_JSON's prs output is an empty array"
jq -e 'all(.[]; (.headBranchName // "") != "")' >/dev/null 2>&1 <<<"$PRS_JSON" \
  || die "an element of PRS_JSON has no headBranchName: $(jq -c '.[] | select((.headBranchName // "") == "")' <<<"$PRS_JSON")"

rc=0
while IFS= read -r branch; do
  log "dispatching $CI_WORKFLOW on $branch"
  gh workflow run "$CI_WORKFLOW" --repo "$GH_REPO" --ref "$branch" \
    || { rc=1; log "could not dispatch $CI_WORKFLOW on $branch (does the job grant actions: write?)"; }
done < <(jq -r '.[].headBranchName // empty' <<<"$PRS_JSON")
[ "$rc" -eq 0 ] || die "one or more release PRs got no CI dispatch"
