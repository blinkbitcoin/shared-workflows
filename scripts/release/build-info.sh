#!/usr/bin/env bash
# Write $WORKFLOWS_RELEASE_META_DIR/build-info.json - the one machine-readable record
# of what a release build actually is. Every later stage reads it: the OTA
# fingerprint gate compares against `fingerprint`, the store lanes read
# `version`/`buildNumber`, and the GitHub release ships it as an asset.
#
# Schema (fixed; adding a key is fine, renaming one is a breaking change):
#   {sha, version, buildNumber, stage, fingerprint:{ios,android},
#    expoSdk, reactNative, workflowRunId, artifacts:{}}
#
# Env: APP_VERSION, APP_BUILD_NUMBER (resolve-version.sh), FINGERPRINT_IOS, FINGERPRINT_ANDROID
# (fingerprint.sh), WORKFLOWS_STAGE, WORKFLOWS_SHA (target-sha.sh; falls back to
# GITHUB_SHA), GITHUB_RUN_ID.
# Usage: build-info.sh [--standalone]
#
# --standalone is for a laptop, where no earlier step ran: whatever is not in the
# environment is worked out here, the way CI's earlier steps would have - the
# version and build number from resolve-version.sh beside this script, and each
# fingerprint from the consumer's fingerprint:generate. Without it a missing
# version stays fatal, because in CI it means resolve-version.sh never ran.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
require_cmd node

standalone=false
case "${1:-}" in
  '') ;;
  --standalone) standalone=true ;;
  *) die "unknown argument: $1 (usage: build-info.sh [--standalone])" ;;
esac

root="$(consumer_root)"
mkdir -p "$WORKFLOWS_RELEASE_META_DIR"
dest="$WORKFLOWS_RELEASE_META_DIR/build-info.json"

if [ "$standalone" = true ]; then
  if [ -z "${APP_VERSION:-}" ] || [ -z "${APP_BUILD_NUMBER:-}" ]; then
    # GITHUB_OUTPUT is cleared so resolving here writes no step outputs.
    resolved="$(GITHUB_OUTPUT='' bash "$(dirname "$0")/resolve-version.sh")" || die "resolve-version.sh failed; see above"
    APP_VERSION="${APP_VERSION:-$(printf '%s\n' "$resolved" | sed -n 's/^APP_VERSION=//p')}"
    APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-$(printf '%s\n' "$resolved" | sed -n 's/^APP_BUILD_NUMBER=//p')}"
  fi
  # Read on a line of their own: inside a command's arguments a failing $(...)
  # would not stop the script.
  if [ -z "${FINGERPRINT_IOS:-}" ]; then FINGERPRINT_IOS="$(workflows_fingerprint ios)" || exit 1; fi
  if [ -z "${FINGERPRINT_ANDROID:-}" ]; then FINGERPRINT_ANDROID="$(workflows_fingerprint android)" || exit 1; fi
  export APP_VERSION APP_BUILD_NUMBER FINGERPRINT_IOS FINGERPRINT_ANDROID
fi

[ -n "${APP_VERSION:-}" ] || die "APP_VERSION is not set - run resolve-version.sh first"
[ -n "${APP_BUILD_NUMBER:-}" ] || die "APP_BUILD_NUMBER is not set - run resolve-version.sh first"

# shellcheck disable=SC2016 # single quotes are deliberate: the ${...} inside the
# program below are JS template literals and must reach node unexpanded.
BUILD_INFO_DEST="$dest" \
  BUILD_INFO_ROOT="$root" \
  BUILD_INFO_SHA="${WORKFLOWS_SHA:-${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)}}" \
  BUILD_INFO_STAGE="${WORKFLOWS_STAGE:-development}" \
  node --input-type=module -e '
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const root = process.env.BUILD_INFO_ROOT;
// A provenance record must say what actually went into the build, so these come
// from the installed package, not from the range in package.json. This copy used
// to read the declared range and strip its operator, which reported 57.0.20 for
// a build that actually ran on 57.0.22, disagreeing with the copy the consumer
// ships on every such build. Resolution starts at the consumer root, so the
// pnpm layout is followed the way the app itself follows it.
//
// No apostrophes in this program: it reaches node inside a single-quoted shell
// string, and one apostrophe ends that string.
const requireFromRoot = createRequire(join(root, "package.json"));
const installed = (name) => {
  try {
    return requireFromRoot(`${name}/package.json`).version ?? null;
  } catch {
    // A consumer without that package installed still gets a build-info.json;
    // the field is null rather than failing the release over provenance.
    return null;
  }
};

const info = {
  sha: process.env.BUILD_INFO_SHA,
  version: process.env.APP_VERSION,
  buildNumber: Number(process.env.APP_BUILD_NUMBER),
  stage: process.env.BUILD_INFO_STAGE,
  fingerprint: {
    ios: process.env.FINGERPRINT_IOS || null,
    android: process.env.FINGERPRINT_ANDROID || null,
  },
  expoSdk: installed("expo"),
  reactNative: installed("react-native"),
  workflowRunId: process.env.GITHUB_RUN_ID || null,
  artifacts: {},
};
writeFileSync(process.env.BUILD_INFO_DEST, JSON.stringify(info, null, 2) + "\n");
'

log "wrote $dest"
cat "$dest" >&2
