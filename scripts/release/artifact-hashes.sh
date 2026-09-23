#!/usr/bin/env bash
# Record the sha256 of the binaries the lane just built in a copy of
# build-info.json, next to those binaries.
#
#   $WORKFLOWS_OUTPUT_DIR/build-info.json = build-info.json + {
#     artifacts: { apkSha256, aabSha256 }
#   }
#   $WORKFLOWS_OUTPUT_DIR/build-info.android.json = the same bytes, under the name
#     that is uploaded with the binaries (see the note above the cp below)
#
# Why a copy rather than an edit in place: the release-meta artifact is produced
# by build-prepare, once, and is downloaded by both platform jobs at the same
# time. Editing it there would make two jobs write the same file, and the
# `artifacts` of an iOS build and an Android build are different things anyway.
# The copy travels with the binaries it describes.
#
# What it is for: the consumer's `verify-android` lane compares the apk it is
# about to hand a human (or a store) against the digest recorded here, so a
# universal apk that was rebuilt, re-signed or swapped between the build step
# and the upload is caught rather than shipped. Downstream, publish-github-release.yml
# stages this copy over the release-meta one, so the release's build-info.json
# is the one that names the bytes actually attached to it.
#
# Env: WORKFLOWS_OUTPUT_DIR (where the lane dropped the .apk/.aab), BUILD_INFO_FILE
#      (default $WORKFLOWS_RELEASE_META_DIR/build-info.json).
# Usage: artifact-hashes.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
require_cmd node

src="${BUILD_INFO_FILE:-$WORKFLOWS_RELEASE_META_DIR/build-info.json}"
[ -f "$src" ] || die "no build-info.json at $src - run build-info.sh (build-prepare) first"
dest="$WORKFLOWS_OUTPUT_DIR/build-info.json"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

# first_of GLOB - the single file matching GLOB, or empty. More than one match
# is fatal: "the apk" has to be unambiguous for a digest to mean anything.
first_of() {
  local pattern="$1" matches=() f
  # Unquoted on purpose: $pattern is the glob being expanded.
  # shellcheck disable=SC2086
  for f in $pattern; do [ -f "$f" ] && matches+=("$f"); done
  [ "${#matches[@]}" -le 1 ] || die "more than one file matches $pattern: ${matches[*]}"
  [ "${#matches[@]}" -eq 0 ] || printf '%s\n' "${matches[0]}"
}

apk="$(first_of "$WORKFLOWS_OUTPUT_DIR/*.apk")"
aab="$(first_of "$WORKFLOWS_OUTPUT_DIR/*.aab")"
apk_sha=""
aab_sha=""
[ -z "$apk" ] || apk_sha="$(sha256_of "$apk")"
[ -z "$aab" ] || aab_sha="$(sha256_of "$aab")"

# shellcheck disable=SC2016  # process.env.* below is JS, not shell expansion
BUILD_INFO_SRC="$src" BUILD_INFO_DEST="$dest" APK_SHA256="$apk_sha" AAB_SHA256="$aab_sha" \
  node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
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
const info = readJson(process.env.BUILD_INFO_SRC);
// Merged, not replaced: build-info.json ships an `artifacts` object precisely
// so each stage can add what it knows without dropping what another wrote.
info.artifacts = { ...(info.artifacts ?? {}) };
if (process.env.APK_SHA256) info.artifacts.apkSha256 = process.env.APK_SHA256;
if (process.env.AAB_SHA256) info.artifacts.aabSha256 = process.env.AAB_SHA256;
writeFileSync(process.env.BUILD_INFO_DEST, JSON.stringify(info, null, 2) + "\n");
'

# A second copy under a platform-specific name is what travels with the
# binaries: a release job merges several artifacts into one directory with no
# defined order, so two artifacts both carrying `build-info.json` would make the
# release's record a coin toss. publish-github-release.yml folds this one back in with
# scripts/release/merge-build-info.sh, which takes only its `artifacts`.
cp "$dest" "$WORKFLOWS_OUTPUT_DIR/build-info.android.json"

log "wrote $dest and $WORKFLOWS_OUTPUT_DIR/build-info.android.json"
if [ -n "$apk_sha" ]; then log "apkSha256=$apk_sha"; else log "no .apk in $WORKFLOWS_OUTPUT_DIR - apkSha256 not recorded"; fi
if [ -n "$aab_sha" ]; then log "aabSha256=$aab_sha"; else log "no .aab in $WORKFLOWS_OUTPUT_DIR - aabSha256 not recorded"; fi
# The verify lane reads the enriched copy, not the one build-prepare produced.
gh_env BUILD_INFO_FILE "$dest"
gh_output apk-sha256 "$apk_sha"
gh_output aab-sha256 "$aab_sha"
