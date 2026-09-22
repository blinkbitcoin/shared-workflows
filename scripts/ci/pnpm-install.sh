#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd pnpm
# Two steps, not `cd "$(consumer_root)"`. A command substitution used as an
# argument does not propagate its exit status, and `cd ""` is a successful
# no-op, so a failing consumer_root would leave this running `pnpm install` in
# whatever directory the runner happened to be in.
root="$(consumer_root)"
cd "$root"
# The failure this catches is a lockfile that exists but disagrees with
# package.json. pnpm says ERR_PNPM_OUTDATED_LOCKFILE in its own words, which
# name neither this workflow family nor the commit that has to be made - and on
# an adopting repository that is the first red of the run.
pnpm install --frozen-lockfile || die_fix \
  "pnpm install --frozen-lockfile failed in $root" \
  "if the lockfile is out of date with package.json, run pnpm install locally and commit pnpm-lock.yaml; CI installs frozen on purpose, so that a build is the dependency tree someone reviewed" \
  "60-second-start"
