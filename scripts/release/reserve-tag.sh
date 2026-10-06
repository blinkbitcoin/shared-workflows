#!/usr/bin/env bash
# Create TAG at SHA now, or confirm it already points there.
#
# Why now and not when the release is published: GitHub treats a *new tag* as
# introducing the workflow files of its commit, compared with the default
# branch's current tip, and refuses GITHUB_TOKEN when any `.github/workflows/*`
# differs ("refusing to allow a GitHub App to create or update workflow ...
# without `workflows` permission"; the releases API only says "HTTP 403:
# Resource not accessible by integration"). A build's release is published
# 15-50 minutes after its push; by then a later merge may have touched a
# workflow, and the `-build.N` tag can no longer be created for that commit.
# Reserving the tag in Prepare, seconds after the push while the commit is
# the tip, sidesteps the rule; the release is later created on the existing
# tag, which creates no ref. Idempotent: a re-run finds its own tag.
#
# Usage: reserve-tag.sh TAG SHA
# Env: GH_TOKEN, GH_REPO. Output: reserved=true when this call created the tag.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh
tag="${1:?usage: reserve-tag.sh TAG SHA}"
sha="${2:?usage: reserve-tag.sh TAG SHA}"
require_env GH_REPO:owner/name

# A lookup that fails for any reason but a 404 is fatal inside gh_ref_exists:
# reading a 401 or a 5xx as "absent" would go on to create the tag blind.
if gh_ref_exists "tags/$tag"; then
  existing="$gh_ref_sha"
  if [ "$existing" = "$sha" ]; then
    log "tag $tag already points at $sha - nothing to reserve"
    gh_output reserved false
    exit 0
  fi
  die "tag $tag already exists at $existing, not at $sha - refusing to build under a tag that names another commit"
fi

if ! err="$(gh api -X POST "repos/$GH_REPO/git/refs" -f ref="refs/tags/$tag" -f sha="$sha" 2>&1 >/dev/null)"; then
  die "could not create tag $tag at $sha: $(printf '%s' "$err" | tr '\n' ' '). If this is 'Resource not accessible by integration', a later commit on the default branch changed a workflow file: GITHUB_TOKEN may not create a tag on a commit whose .github/workflows differ from the tip. Re-run once they match, or configure the RELEASE_TAGGER App."
fi
log "reserved tag $tag at $sha"
gh_output reserved true
