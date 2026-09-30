#!/usr/bin/env bash
# Download a release's assets into the directory a store lane reads.
#
# For a lane whose binary is not in this run. A promotion stage builds nothing,
# so a store without a promote endpoint - Huawei AppGallery - gets a fresh
# upload of the bundle the release already carries, and download-artifact
# cannot reach it: it only sees the current run's artifacts. The release
# asset is also the exact bytes the other stores received.
#
#   no tag                      fails, naming the input that is missing
#   no asset matches, or the    fails with gh's own reason: the lane needs the
#   download breaks             file, and running it without one uploads nothing
#
# Usage: release-assets-fetch.sh TAG PATTERN DIR   Env: GH_TOKEN, GH_REPO.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh

tag="${1:-}"
pattern="${2:?usage: release-assets-fetch.sh TAG PATTERN DIR}"
dir="${3:?usage: release-assets-fetch.sh TAG PATTERN DIR}"
[ -n "$tag" ] || die_fix \
  "release-assets is $pattern, but no release-tag says which release to take them from" \
  "pass release-tag: <the release whose assets the lane needs> to publish-store.yml" \
  "publish-storeyml"

mkdir -p "$dir"
err="$(gh release download "$tag" --pattern "$pattern" --dir "$dir" --clobber 2>&1 >/dev/null)" \
  || die "could not download $pattern from release $tag in ${GH_REPO:-this repository}: $err"
files="$(find "$dir" -maxdepth 1 -type f -name "$pattern" -exec basename {} \; | sort)"
log "release $tag: $(tr '\n' ' ' <<<"$files")into $dir"
