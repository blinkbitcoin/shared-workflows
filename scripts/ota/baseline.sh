#!/usr/bin/env bash
# Fetch the fingerprint baseline for an OTA channel: the `build-info.json`
# asset of the GitHub release that produced the store build currently installed
# on that channel.
#
# It has to come from a *release asset*, not from an artifact of the current
# run. `actions/download-artifact` can only see artifacts produced by the run it
# executes in, so wiring the gate to a same-run artifact compares the current
# commit's fingerprint against itself and the gate passes unconditionally - the
# exact failure this script exists to make impossible. A missing asset is fatal
# for the same reason: there is no such thing as a silent pass here.
#
# Usage: baseline.sh TAG [DEST]   (default DEST: $WORKFLOWS_ASSETS_DIR/build-info.json)
# Env: GH_TOKEN, GH_REPO.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
require_cmd gh

tag="${1:-}"
[ -n "$tag" ] || die "no baseline tag given - publish-ota's baseline-tag input is required whenever ota-enabled is true"
dest="${2:-$WORKFLOWS_ASSETS_DIR/build-info.json}"

mkdir -p "$(dirname "$dest")"
rm -f "$dest"

group "ota baseline ($tag)"
gh release download "$tag" --pattern build-info.json --output "$dest" --clobber ||
  die "could not download build-info.json from release $tag - is the tag right, and was that release created by publish-github-release.yml?"
endgroup

[ -s "$dest" ] || die "release $tag has no build-info.json asset, so this channel has no fingerprint baseline; publish a store build through build-prepare + publish-github-release first"
log "baseline for the gate: $dest"
cat "$dest" >&2
