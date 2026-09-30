#!/usr/bin/env bash
# Render the badges publish-badges.yml publishes, into the consumer's
# BADGE_OUT_DIR, before publish-badges.sh copies them to gh-pages.
#
# By default with the gen-badges program @blinkbitcoin/app-tooling ships,
# from this repository's own checkout: the same commit as the workflow that
# runs it, so a consumer needs no script, no copy and no installed package for
# it. A caller that renders its own badges names its package script in
# `badges-script` (RENDER_SCRIPT here), and that script runs through
# run-script.sh instead, exactly as before.
#
# Everything the renderer reads (BADGE_OUT_DIR, BADGE_UNIT, BADGE_E2E, the
# labels, BADGE_SECURITY) is already in the environment; its defaults are paths
# relative to the consumer root, which is why it runs from there.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

script="${RENDER_SCRIPT:-}"
if [ -n "$script" ]; then
  log "badges: rendering with the consumer's \"$script\" script (badges-script)"
  exec bash "$(dirname "$0")/../checks/run-script.sh" "$script"
fi

renderer="$(cd "$(dirname "$0")/../.." && pwd)/packages/app-tooling/bin/gen-badges.mjs"
[ -f "$renderer" ] || die "gen-badges.sh: no renderer at $renderer"

# Two steps, not `cd "$(consumer_root)"`: a command substitution used as an
# argument does not propagate its exit status, and `cd ""` is a successful
# no-op. Same reason as check-contract.sh.
root="$(consumer_root)"
cd "$root"
log "badges: rendering with @blinkbitcoin/app-tooling's gen-badges"
exec node "$renderer"
