#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd git

require_env "TAG:a release-please tag_name output, e.g. v0.1.0"

if [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-.+$ ]]; then
  log "skipping prerelease tag '$TAG' (moving major/minor tags only track full releases)"
  exit 0
fi

[[ "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || die "TAG '$TAG' is not a plain vX.Y.Z tag"
major="v${BASH_REMATCH[1]}"
minor="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"

local_only=0
for arg in "$@"; do
  [ "$arg" = "--local" ] && local_only=1
done

sha="$(git rev-parse "$TAG^{commit}")"

for t in "$major" "$minor"; do
  log "moving $t -> $sha ($TAG)"
  git tag -f "$t" "$sha" >/dev/null
done

if [ "$local_only" -eq 1 ]; then
  log "skipping push (--local)"
  exit 0
fi

git push -f origin "$major" "$minor"
