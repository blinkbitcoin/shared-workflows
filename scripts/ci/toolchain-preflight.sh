#!/usr/bin/env bash
# Assert the consumer provides the toolchain the setup action is about to use.
#
# Why this runs before jdx/mise-action rather than after it. mise-action with no
# config to read installs nothing and succeeds: it has nothing to complain
# about. The first sign of trouble is then two steps later, in
# pnpm-store-path.sh, as `missing command: pnpm` - a true sentence naming
# neither the file that is missing nor the repository it is missing from. Every
# job of every workflow in this family dies there, identically.
#
# The lockfile is checked here for the same reason: `pnpm install
# --frozen-lockfile` reports ERR_PNPM_NO_LOCKFILE in pnpm's own words, which
# mention nothing about this workflow family or what it expects.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

root="$(consumer_root)"

mise_config=""
for name in .mise.toml mise.toml .config/mise/config.toml .tool-versions; do
  if [ -f "$root/$name" ]; then
    mise_config="$name"
    break
  fi
done

[ -n "$mise_config" ] || die_fix \
  "no mise config in $root - the setup action installs node and pnpm from one, and with none it installs nothing" \
  "add a .mise.toml with a [tools] table declaring at least node and pnpm, or run check-consumer-contract for the full list" \
  "the-contract-check"

[ -f "$root/package.json" ] || die_fix \
  "no package.json in $root - every gate in this family runs a script from one" \
  "this family runs a consumer's package.json scripts by name; a repository without one cannot satisfy any gate" \
  "script-contract"

[ -f "$root/pnpm-lock.yaml" ] || die_fix \
  "no pnpm-lock.yaml in $root - the setup action installs with --frozen-lockfile, and the native cache key is read straight out of the lockfile before any install runs" \
  "run pnpm install and commit pnpm-lock.yaml; this family is pnpm-only, there is no npm or yarn path" \
  "60-second-start"

log "toolchain preflight: $mise_config, package.json and pnpm-lock.yaml are present"
