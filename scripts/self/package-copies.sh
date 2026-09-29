#!/usr/bin/env bash
# Keep the release scripts the dev-config package ships byte-identical to the
# ones the workflows run.
#
# build-prepare.yml runs scripts/release/resolve-version.sh and build-info.sh;
# a consumer runs the same two on a laptop (`make version`, a local build-info
# run), where it has the package and not this repository. The package
# therefore carries them, with the two libraries they source, at the same
# relative paths (release/ beside lib/, as scripts/release/ sits beside
# scripts/lib/), so each copy runs unchanged. Copies inside one repository,
# held identical on every commit by test/package-copies.bats, cannot drift the
# way a consumer's own copy did: that one was compared only in the consumer's
# CI, and only when a shared-workflows checkout was at hand.
#
# Usage: package-copies.sh           check: fail naming every stale copy
#        package-copies.sh --write   refresh every copy from its original
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

root="$(cd "$(dirname "$0")/../.." && pwd)"
copies=(release/resolve-version.sh release/build-info.sh lib/common.sh lib/release-env.sh)

write=false
case "${1:-}" in
  '') ;;
  --write) write=true ;;
  *) die "unknown argument: $1 (usage: package-copies.sh [--write])" ;;
esac

stale=()
for rel in "${copies[@]}"; do
  original="$root/scripts/$rel"
  copy="$root/packages/dev-config/$rel"
  [ -f "$original" ] || die "no $original to copy into the package"
  if [ "$write" = true ]; then
    mkdir -p "$(dirname "$copy")"
    cp -p "$original" "$copy"
  elif ! cmp -s "$original" "$copy"; then
    stale+=("packages/dev-config/$rel")
  fi
done

if [ "$write" = true ]; then
  log "copied ${#copies[@]} files into packages/dev-config"
  exit 0
fi
[ "${#stale[@]}" -eq 0 ] || die "the package's copies differ from what the workflows run: ${stale[*]} - run: bash scripts/self/package-copies.sh --write"
log "package copies ok (${#copies[@]} files)"
