#!/usr/bin/env bash
# Fetch a GitHub release's body into $WORKFLOWS_OUT/release-body.md and point
# RELEASE_BODY_FILE at it, so notes.sh generates store notes from what was
# actually published rather than from the commit log.
#
# The body is the human-written release text (release-please's changelog, or an
# editor's own words); the commit subjects are the fallback for when no release
# exists yet. Preferring the body is what makes the store listing read like a
# release note instead of a git log.
#
# Usage: release-body.sh TAG
# Env: GH_TOKEN, GH_REPO.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
require_cmd gh

tag="${1:-}"
[ -n "$tag" ] || die "no release tag given - build-prepare's release-tag input is empty"
dest="$WORKFLOWS_OUT/release-body.md"

group "release body ($tag)"
gh release view "$tag" --json body --jq '.body' > "$dest" ||
  die "could not read the body of release $tag - does that release exist?"
# An empty body is fatal rather than a silent fallback to commit subjects: the
# caller asked for this release's notes specifically, and shipping a git log to
# the stores instead would look like it worked.
[ -s "$dest" ] || die "release $tag has an empty body - nothing to generate store notes from"
endgroup

log "wrote $dest ($(wc -l < "$dest" | tr -d ' ') lines)"
gh_env RELEASE_BODY_FILE "$dest"
