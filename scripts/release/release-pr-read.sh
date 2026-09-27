#!/usr/bin/env bash
# Publish the release PR's number and branch as step outputs, from
# release-please's singular `pr` output (the root package's PR), for a caller's
# store-notes job to write into.
#
# Read here, in the shell, not with fromJSON() in a step's `env:`: the runner
# validates a step's env expressions even when its `if` is false, and
# fromJSON('') is a template error - it failed the template's release job on
# the first push that produced no release PR.
#
# Usage: release-pr-read.sh   Env: PR_JSON (release-please's `pr` output).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd jq

[ -n "${PR_JSON:-}" ] || die "PR_JSON is empty: release-please reported a PR but passed no pr output"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$PR_JSON" || die "PR_JSON is not a JSON object: $PR_JSON"
number="$(jq -r '.number // empty' <<<"$PR_JSON")"
branch="$(jq -r '.headBranchName // empty' <<<"$PR_JSON")"
[ -n "$number" ] && [ -n "$branch" ] \
  || die "release-please reported a PR but its pr output lacks number or headBranchName: $PR_JSON"
gh_output number "$number"
gh_output branch "$branch"
log "release PR #$number on $branch"
