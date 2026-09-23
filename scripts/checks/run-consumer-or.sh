#!/usr/bin/env bash
# Run the consumer's own NAME package script when it ships one; otherwise run
# this repo's FALLBACK implementation of the same gate.
#
# Why this exists. Most checks in check-code.yml already delegate to the consumer
# through run-script.sh: typecheck, lint, format, knip, spell, check:docs,
# check:release. Five did not - i18n, codegen, expo-doctor, audit and the CI
# linters were implemented here and *only* here - and those five are exactly the
# ones that drifted from the consumer's own `make check`:
#
#   - this repo's expo-doctor.sh runs `expo-doctor`, while the template's
#     `deps:check` runs `expo install --check && expo-doctor`, so SDK version
#     drift was checked on a laptop and nowhere in CI;
#   - this repo's audit.sh runs `pnpm audit`, while the template's `deps:audit`
#     also runs its lockfile provenance check, so that ran nowhere in CI either.
#
# A consumer that ships a script for a gate has said what that gate means for
# its repository. Running something else in CI makes a green `make check` a
# claim about coverage CI does not have. So: the consumer's script wins, and the
# implementation here is the fallback for a consumer that has none.
#
# Which branch was taken is logged on purpose. "Was that the consumer's script
# or the fallback?" is the question this whole seam exists to answer, and a run
# log that cannot answer it is how the drift above went unnoticed.
#
# Usage: run-consumer-or.sh NAME FALLBACK
#   NAME      a consumer package.json script name (e.g. deps:audit)
#   FALLBACK  path to a script in this repo, relative to the repo root
#             (e.g. scripts/checks/audit.sh)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node pnpm

name="${1:?usage: run-consumer-or.sh NAME FALLBACK}"
fallback="${2:?usage: run-consumer-or.sh NAME FALLBACK}"

here="$(cd "$(dirname "$0")/../.." && pwd)"
fallback_path="$here/$fallback"
# Checked before the consumer probe, not after: a typo in a workflow's fallback
# path must fail loudly on every run, not only on the consumers that happen to
# lack the script and so are the only ones that would ever reach it.
[ -f "$fallback_path" ] || die "run-consumer-or.sh: no fallback script at $fallback_path"

root="$(consumer_root)"

has_script() {
  RUN_SCRIPT_NAME="$name" node -e \
    "process.exit(require('./package.json').scripts?.[process.env.RUN_SCRIPT_NAME] ? 0 : 1)" \
    2>/dev/null
}

if (cd "$root" && has_script); then
  log "$name: running the consumer's own script"
  exec bash "$(dirname "$0")/run-script.sh" "$name"
else
  log "$name: the consumer ships no \"$name\" script - running $fallback from shared-workflows"
  exec bash "$fallback_path"
fi
