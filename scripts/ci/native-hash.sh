#!/usr/bin/env bash
# Hash of every input the native (Xcode/Gradle) build consumes in an Expo prebuild app:
# the lockfile-resolved versions of runtime deps + native-adjacent dev deps, plus the
# config/plugin/module/patch files. A jest/eslint bump does not change it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
root="${1:-$(consumer_root)}"
require_cmd yq shasum
lock="$root/pnpm-lock.yaml"; [ -f "$lock" ] || die "no pnpm-lock.yaml in $root"
# Assert the shape before reading it. Every query below is `.importers["."]…`,
# which is lockfile v9. On an older lockfile - or a workspace whose root is not
# "." - those queries return nothing and `// {}` turns that into an empty list
# WITHOUT an error: the hash is then computed from the config files alone, the
# cache key stops tracking dependency versions entirely, and a native dependency
# bump silently restores a stale build. A wrong answer no one is told about is
# worse than a failure, so this is fatal rather than a warning.
yq -e '.importers["."]' "$lock" >/dev/null 2>&1 || die_fix \
  "$lock has no importers[\".\"] - this reads a pnpm lockfile v9 written at the repository root" \
  "upgrade the lockfile with a current pnpm (pnpm install), or, for a workspace whose app is not at the root, point working-directory at the package that owns pnpm-lock.yaml" \
  "60-second-start"
deps=$(yq -r '.importers["."].dependencies // {} | to_entries[] | (.key + "@" + .value.version)' "$lock")
# The prefix test below is intentionally unanchored at the end (no trailing
# `/` or `$`), so it also matches e.g. expo-doctor and react-native-web, not
# just the packages literally named expo/react-native/etc. That's deliberate:
# most expo-*/react-native-* devDependencies are native-adjacent (config
# plugins, codegen, native modules), and the cost of a false positive here is
# only an occasional unnecessary rebuild, never a missed native change.
devs=$(yq -r '.importers["."].devDependencies // {} | to_entries[] | select(.key | test("^(expo|@expo/|react-native|@react-native|@react-native-community|@config-plugins/|patch-package)")) | (.key + "@" + .value.version)' "$lock")
files=$(cd "$root" && find . -maxdepth 1 \( -name 'app.config.*' -o -name 'app.json' -o -name 'Gemfile.lock' -o -name '.mise.toml' -o -name 'google-services.json' -o -name 'GoogleService-Info.plist' \) -type f | sort)
dirs=$(cd "$root" && for d in plugins modules patches; do [ -d "$d" ] && find "$d" -type f | sort; done || true)
# NATIVE_EXTRA_GLOBS is a space-separated list of consumer-relative shell globs
# (e.g. 'fastlane/*.rb native/*'). The *contents* of the matched files are
# folded in, not just the pattern - a consumer adding a glob expects a change to
# those files to invalidate the cache. No recursive `**`: bash 3.2 (the macOS
# system bash these scripts must run under) has no globstar.
extra=""
if [ -n "${NATIVE_EXTRA_GLOBS:-}" ]; then
  # shellcheck disable=SC2086 # deliberate: the globs must word-split and expand
  # `if`, not `[ -f "$m" ] && printf`: under `set -e` a failing test as the
  # first half of an AND-list aborts the subshell, which would silently
  # truncate the list (and fail the assignment).
  extra=$(cd "$root" && for p in $NATIVE_EXTRA_GLOBS; do
    for m in $p; do
      if [ -f "$m" ]; then printf '%s\n' "$m"; fi
    done
  done | sort -u)
fi
{
  printf '%s\n' "$deps" "$devs"
  # Word-splitting $files/$dirs/$extra here assumes consumer paths contain no
  # spaces or glob metacharacters (true for this repo's real consumers, an
  # Expo app tree); switch to `while IFS= read -r f` if that ever changes.
  for f in $files $dirs $extra; do printf '%s ' "$f"; shasum -a 256 "$root/$f" | cut -c1-64; done
  printf 'extra=%s\n' "${NATIVE_EXTRA_GLOBS:-}"
} | shasum -a 256 | cut -c1-16
