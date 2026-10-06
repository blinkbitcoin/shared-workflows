#!/usr/bin/env bash
# Record the sha256 of the binaries a platform's build lane just produced in a
# copy of build-info.json, next to those binaries.
#
#   android (the default): artifacts.apkSha256 and artifacts.aabSha256
#   ios:                   artifacts.ipaSha256
#
#   $WORKFLOWS_OUTPUT_DIR/build-info.json = build-info.json + { artifacts: {...} }
#   $WORKFLOWS_OUTPUT_DIR/build-info.<platform>.json = the same bytes, under the
#     name that is uploaded with the binaries (see the note above the cp below)
#
# Why a copy rather than an edit in place: the build-info artifact is produced
# by build-prepare, once, and is downloaded by both platform jobs at the same
# time. Editing it there would make two jobs write the same file, and the
# `artifacts` of an iOS build and an Android build are different things anyway.
# The copy travels with the binaries it describes.
#
# What it is for: the consumer's `verify-android` lane compares the apk it is
# about to hand a human (or a store) against the digest recorded here, so a
# universal apk that was rebuilt, re-signed or swapped between the build step
# and the upload is caught rather than shipped. Downstream, publish-github-release.yml
# stages this copy over the build-info one, so the release's build-info.json
# is the one that names the bytes actually attached to it. The ios digest has no
# verify check reading it yet; it is the release record's name for the .ipa.
#
# A binary that is not there (an unsigned iOS build packages no .ipa) is
# recorded as absent, never as an empty digest; more than one of a kind is fatal.
#
# Env: WORKFLOWS_OUTPUT_DIR (where the lane dropped the binaries), BUILD_INFO_FILE
#      (default $WORKFLOWS_RELEASE_META_DIR/build-info.json).
# Usage: artifact-hashes.sh [android|ios]
# Outputs: android: apk-sha256, aab-sha256; ios: ipa-sha256 (each empty when
#          that binary is absent).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
require_cmd node

usage='usage: artifact-hashes.sh [android|ios]'
[ "$#" -le 1 ] || die "too many arguments: $* ($usage)"
# `-`, not `:-`: no argument is android, but an empty one is a caller's
# expression that came out blank, and is refused below rather than guessed.
platform="${1-android}"
# The binary types a platform's lane produces, in the order they are recorded.
case "$platform" in
  android) kinds=(apk aab) ;;
  ios) kinds=(ipa) ;;
  *) die "unknown platform: $platform ($usage)" ;;
esac

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

# shas[i] is the digest of kinds[i], empty when there is no such binary. Indexed
# arrays, not an associative one: macOS's /bin/bash is 3.2. Every file is
# looked up before any is hashed, so an ambiguous one fails before any work.
files=()
for kind in "${kinds[@]}"; do
  file="$(first_of "$WORKFLOWS_OUTPUT_DIR/*.$kind")"
  files+=("$file")
done
shas=()
pairs=()
for i in "${!kinds[@]}"; do
  sha=""
  [ -z "${files[$i]}" ] || sha="$(sha256_of "${files[$i]}")"
  shas+=("$sha")
  pairs+=("${kinds[$i]}Sha256=$sha")
done

node "$(dirname "$0")/artifact-hashes.mjs" "$src" "$dest" "${pairs[@]}"

# A second copy under a platform-specific name is what travels with the
# binaries: a release job merges several artifacts into one directory with no
# defined order, so two artifacts both carrying `build-info.json` would make the
# release's record a coin toss. publish-github-release.yml folds this one back in with
# scripts/release/merge-build-info.sh, which takes only its `artifacts`.
cp "$dest" "$WORKFLOWS_OUTPUT_DIR/build-info.$platform.json"

log "wrote $dest and $WORKFLOWS_OUTPUT_DIR/build-info.$platform.json"
for i in "${!kinds[@]}"; do
  if [ -n "${shas[$i]}" ]; then log "${kinds[$i]}Sha256=${shas[$i]}"
  else log "no .${kinds[$i]} in $WORKFLOWS_OUTPUT_DIR - ${kinds[$i]}Sha256 not recorded"; fi
done
# The verify lane reads the enriched copy, not the one build-prepare produced.
gh_env BUILD_INFO_FILE "$dest"
for i in "${!kinds[@]}"; do
  gh_output "${kinds[$i]}-sha256" "${shas[$i]}"
done
