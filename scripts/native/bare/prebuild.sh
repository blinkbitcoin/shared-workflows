#!/usr/bin/env bash
# The bare stack's prebuild: there is nothing to generate. A bare React Native
# app commits ios/ and android/ as source, so this only checks that the tree a
# build is about to read is there and is the committed one - an untracked
# ios/ left over from somewhere else would build an app nobody reviewed.
# scripts/native/prebuild.sh dispatches here through scripts/lib/native-stack.sh.
# Usage: prebuild.sh <ios|android>
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
source "$(dirname "$0")/../../lib/e2e-env.sh"

platform="$(workflows_platform "${1:-}")"
root="$(consumer_root)"

[ -d "$root/$platform" ] || die_fix \
  "no $platform/ in $root, and the bare native stack builds the committed $platform/ project" \
  "commit the $platform/ project, or, for an Expo app whose $platform/ is prebuild output, pass native-stack: expo" \
  "expo-or-bare"

tracked="$(git -C "$root" ls-files -- "$platform" 2>/dev/null)" || tracked=""
[ -n "$tracked" ] || die_fix \
  "$root/$platform exists but git tracks none of it, and the bare native stack builds only the committed $platform/ project" \
  "commit $platform/ (and take it out of .gitignore), or, for an Expo app whose $platform/ is prebuild output, pass native-stack: expo" \
  "expo-or-bare"

log "bare native stack: $platform/ is committed ($(printf '%s\n' "$tracked" | wc -l | tr -d ' ') tracked files), nothing to generate"
