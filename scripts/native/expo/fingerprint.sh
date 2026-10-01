#!/usr/bin/env bash
# The Expo stack's native fingerprint for one platform: @expo/fingerprint's
# hash, printed alone on stdout. scripts/lib/native-stack.sh dispatches here;
# callers ask through workflows_fingerprint in scripts/lib/release-env.sh.
#
# The CLI is @expo/fingerprint's `fingerprint` bin (verified against the
# installed version): `fingerprint fingerprint:generate --platform ios`, run in
# the consumer root so the consumer's fingerprint.config.js is picked up
# automatically. It prints a JSON object carrying `.hash`; a bare-hash output
# from an older version is still accepted.
#
# `npx --no`, not `npx --yes`: the bin must come from the consumer's own
# devDependency. `--yes` would happily install some unrelated npm package
# called "fingerprint" and hash the app with it.
# Usage: fingerprint.sh <ios|android>
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
source "$(dirname "$0")/../../lib/release-env.sh"

platform="$(workflows_release_platform "${1:-}")"
require_cmd npx
root="$(consumer_root)" || die "the consumer's working directory does not exist: ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.}"
out="$(cd "$root" && npx --no fingerprint fingerprint:generate --platform "$platform")" ||
  die "fingerprint:generate failed for $platform (is @expo/fingerprint a devDependency of the consumer?)"
case "$out" in
  *'{'*)
    # node, not yq: app-tooling ships this script to laptops that run
    # build-info.sh --standalone, where node is always present and yq may not be.
    # Output that does not parse reads as no hash, which the check below reports.
    require_cmd node
    out="$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",(c)=>{s+=c}).on("end",()=>{let h="";try{h=JSON.parse(s).hash}catch{}process.stdout.write(typeof h==="string"?h:"")})')"
    ;;
  *)
    out="$(printf '%s\n' "$out" | tr -d '[:space:]')"
    ;;
esac
[ -n "$out" ] || die "could not read a fingerprint hash for $platform out of fingerprint:generate's output"
printf '%s\n' "$out"
