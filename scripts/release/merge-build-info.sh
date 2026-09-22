#!/usr/bin/env bash
# Fold the per-platform build-info records staged in a directory into the one
# build-info.json that ships on the release.
#
#   build-info.json           the record expo-prepare produced (release-meta)
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
# stays as expo-prepare wrote it, because a platform copy is a *snapshot* of
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
  # No release-meta record staged (a caller with notes-artifact: ''), so the
  # platform copy is the only record there is.
  log "no build-info.json in $dir - seeding it from ${overlays[0]}"
  cp "${overlays[0]}" "$base"
fi

require_cmd node
group "merge build-info"
log "base: $base"
for f in "${overlays[@]}"; do log "overlay: $f"; done
# shellcheck disable=SC2016  # process.env.* below is JS, not shell expansion
BUILD_INFO_BASE="$base" node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
const base = process.env.BUILD_INFO_BASE;
// A file that is not JSON is a wrong artifact or a truncated download, and the
// reader must say which file rather than answering with a node stack trace.
const readJson = (f) => {
  try {
    return JSON.parse(readFileSync(f, "utf8"));
  } catch (error) {
    console.error(`::error::${f} is not readable as JSON: ${error.message}`);
    process.exit(1);
  }
};
const info = readJson(base);
info.artifacts = { ...(info.artifacts ?? {}) };
// slice(1): with `node -e`, argv is [execPath, ...args] - there is no script
// path in it, so the usual slice(2) would silently drop the first overlay.
for (const f of process.argv.slice(1)) {
  const overlay = readJson(f);
  // Only artifacts: see the header. A platform copy is a snapshot of the base
  // record and must not be able to put a stale sha or stage back on it.
  info.artifacts = { ...info.artifacts, ...(overlay.artifacts ?? {}) };
}
writeFileSync(base, JSON.stringify(info, null, 2) + "\n");
' "${overlays[@]}"
cat "$base" >&2
endgroup
