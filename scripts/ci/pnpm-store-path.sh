#!/usr/bin/env bash
# Print the pnpm content-addressable store path for the consumer, and the hash
# of the consumer's own pnpm-lock.yaml, so CI can key a cache on them.
#
# The hash is of that one file, not hashFiles('**/pnpm-lock.yaml'): this
# repository is checked out inside the workspace as .workflows/, and its test
# fixtures carry lockfiles of their own, so a glob changed every consumer's key
# whenever a fixture changed. No lockfile hashes as "none" rather than failing:
# the install that needs one says so itself, and this step must not be the
# first to fail for a reason it does not own.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd pnpm shasum
# Two steps: a command substitution used as an argument does not propagate its
# exit status, and `cd ""` is a successful no-op, so a failing consumer_root
# would silently report the store path of the wrong directory.
root="$(consumer_root)"
path=$(cd "$root" && pnpm store path)
if [ -f "$root/pnpm-lock.yaml" ]; then
  lock_hash="$(shasum -a 256 "$root/pnpm-lock.yaml" | cut -d' ' -f1)"
else
  lock_hash=none
fi
gh_output path "$path"
gh_output lock-hash "$lock_hash"
