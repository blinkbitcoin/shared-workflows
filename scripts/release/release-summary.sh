#!/usr/bin/env bash
# Write what release-please released to the job summary.
#
# A caller that acts on one package of a multi-package release keys off the
# `paths-released` output, and a path it spells wrong matches nothing: the job
# it gates skips instead of failing. Printing what was actually released puts
# that mistake in the run, not months later in a missing package version.
#
# Usage: release-summary.sh   Env: PATHS_RELEASED (release-please's
# `paths_released` output; empty on a push that released nothing),
# GITHUB_STEP_SUMMARY (the summary is also logged when it is unset).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

line="paths released: ${PATHS_RELEASED:-none}"
log "$line"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || gh_summary "$line"
