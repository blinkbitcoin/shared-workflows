#!/usr/bin/env bash
# Delete TAG. The counterpart of reserve-tag.sh, for a run that reserved its
# build tag and then could not fill it (a red green-gate, a failed build): a
# tag naming a commit with no release would otherwise stay behind.
#
# Usage: unreserve-tag.sh TAG
# Env: GH_TOKEN, GH_REPO.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh
tag="${1:?usage: unreserve-tag.sh TAG}"
require_env GH_REPO:owner/name
gh api -X DELETE "repos/$GH_REPO/git/refs/tags/$tag" >/dev/null
log "deleted tag $tag"
