#!/usr/bin/env bash
# The bare stack's native fingerprint for one platform, printed alone on
# stdout like @expo/fingerprint's: a sha256 over every file a store build of
# that platform reads natively. scripts/lib/native-stack.sh dispatches here;
# callers ask through workflows_fingerprint in scripts/lib/release-env.sh.
#
# What it covers, per platform:
#   - every file git tracks under ios/ (for ios) or android/ (for android) -
#     the native project is committed source in a bare app, so its tracked
#     files are exactly what a build compiles;
#   - pnpm-lock.yaml, so a native dependency bump changes it;
#   - every file matched by NATIVE_EXTRA_GLOBS (the `native-extra-globs`
#     input): space-separated, consumer-relative shell globs, not recursive,
#     the same rule scripts/ci/native-hash.sh applies.
# Each file contributes its sha256 and path, in byte order of the paths, so the hash is
# stable across machines and changes when a file is added, removed, renamed or
# edited. File contents come from the working tree: in CI that is the commit.
# Usage: fingerprint.sh <ios|android>
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
source "$(dirname "$0")/../../lib/release-env.sh"

platform="$(workflows_release_platform "${1:-}")"
require_cmd git shasum
root="$(consumer_root)" || die "the consumer's working directory does not exist: ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.}"
cd "$root"

[ -f pnpm-lock.yaml ] || die_fix "no pnpm-lock.yaml in $root, so the $platform fingerprint cannot cover the dependencies" \
  "commit the lockfile (pnpm install writes it)" "expo-or-bare"

# Listed into variables before use: a failure in a `< <(...)` feeding a loop
# would not stop the script.
tracked="$(git ls-files -- "$platform")" ||
  die "git could not list the files under $root/$platform (is this a git checkout?)"
[ -n "$tracked" ] || die_fix "git tracks no file under $root/$platform, so there is no native project to fingerprint" \
  "commit $platform/, or pass native-stack: expo for an app whose $platform/ is prebuild output" "expo-or-bare"

extra=""
if [ -n "${NATIVE_EXTRA_GLOBS:-}" ]; then
  # shellcheck disable=SC2086 # deliberate: the globs must word-split and expand
  extra="$(for pattern in $NATIVE_EXTRA_GLOBS; do
    for match in $pattern; do
      if [ -f "$match" ]; then printf '%s\n' "$match"; fi
    done
  done)"
fi

files="$(printf '%s\n%s\n%s\n' "$tracked" pnpm-lock.yaml "$extra" | grep . | env LC_ALL=C sort -u)"
# One shasum for all of them (an ios/ tree is thousands of files, and a process
# per file is minutes); a tracked file deleted in the working tree is part of
# the change, not an error, so it is listed as deleted instead.
present=""
deleted=""
while IFS= read -r file; do
  if [ -f "$file" ]; then
    present="$present$file
"
  else
    deleted="${deleted}deleted  $file
"
  fi
done <<< "$files"
# Never empty: the lockfile was checked above.
sums="$(printf '%s' "$present" | tr '\n' '\0' | xargs -0 shasum -a 256)" ||
  die "could not hash the $platform files in $root"
printf '%s\n%s' "$sums" "$deleted" | shasum -a 256 | cut -c1-64
