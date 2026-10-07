#!/usr/bin/env bash
# Fold the per-platform build-info records staged in a directory into the one
# build-info.json that ships on the release.
#
#   build-info.json           the record build-prepare produced (build-info)
#   build-info.<platform>.json  the same record plus that platform's
#                             `artifacts` digests, written by artifact-hashes.sh
#
# Why the platform copies are not called `build-info.json`: a release job stages
# several artifacts into one directory with `merge-multiple: true`, and that
# merge has **no defined order**. Two artifacts carrying the same filename would
# make "which build-info.json ends up on the release" a coin toss - and the
# losing side is either the digests (silently absent) or the whole record. A
# distinct name per platform makes the collision impossible, and this script
# makes the precedence explicit instead of leaving it to the downloader.
#
# Precedence: only `artifacts` is taken from the platform copies (later ones win
# key by key). Everything else - sha, version, buildNumber, stage, fingerprint -
# stays as build-prepare wrote it, because a platform copy is a *snapshot* of
# that record taken mid-job and must never be able to reintroduce a stale value.
# When there is no base record at all, the first platform copy becomes it.
#
# Env: WORKFLOWS_ASSETS_DIR (default target directory).
# Usage: merge-build-info.sh [DIR]
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"

dir="${1:-$WORKFLOWS_ASSETS_DIR}"
[ -d "$dir" ] || { log "no $dir - nothing to merge"; exit 0; }

overlays=()
for f in "$dir"/build-info.*.json; do
  [ -f "$f" ] && overlays+=("$f")
done
if [ "${#overlays[@]}" -eq 0 ]; then
  log "no per-platform build-info records in $dir - nothing to merge"
  exit 0
fi

base="$dir/build-info.json"
if [ ! -f "$base" ]; then
  # No build-info record staged (a caller with release-notes-artifact: ''), so the
  # platform copy is the only record there is.
  log "no build-info.json in $dir - seeding it from ${overlays[0]}"
  cp "${overlays[0]}" "$base"
fi

require_cmd node
group "merge build-info"
log "base: $base"
for f in "${overlays[@]}"; do log "overlay: $f"; done
# The precedence rule above is merge-build-info.mjs's, beside this script: it
# rewrites $base in place, and names the file when one is not JSON.
node "$(dirname "$0")/merge-build-info.mjs" "$base" "${overlays[@]}"
cat "$base" >&2
endgroup
