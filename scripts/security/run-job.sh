#!/usr/bin/env bash
# Run one of the consumer's security runners, and insist it reported.
#
# Usage: run-job.sh JOB
#
# Shared ships no fallback runner. A job that is switched on but whose
# scripts/security/<job>.sh does not exist fails here, by name - it never skips
# quietly, because a pipeline that scans nothing while reporting green is worse
# than one that is red. When a second, non-template consumer appears, the shared
# subset moves into @blinkbitcoin/dev-config; a duplicate here would serve
# nobody today.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

job="${1:?usage: run-job.sh JOB}"
root="$(consumer_root)"
cd "$root"

runner="scripts/security/$job.sh"
[ -f "$runner" ] || die_fix \
  "the $job scanner is switched on, but this repository has no $runner" \
  "add $runner, or set \"jobs\": { \"$job\": { \"enabled\": false } } in security-policy.json, or pass $job: false to check-security.yml" \
  "check-securityyml"

out="${SECURITY_DIR:-.security}"
mkdir -p "$out"
# A finding never fails a runner: the runner exits 0 with findings, and only the
# verdict fails on them. A non-zero exit here is a crash - a missing binary
# under CI, a bad config, output that is not SARIF - and errexit hands its
# status straight back, so the run names the scanner that died.
bash "$runner"

sarif="$out/$job.sarif"
# -s, not -f: a zero-byte file is the same silence as no file. A runner that
# exits 0 without reporting would reach the verdict as nothing at all, and the
# verdict cannot tell "found nothing" from "reported nothing".
[ -s "$sarif" ] || die "$runner exited 0 but left no $sarif. Every runner writes exactly one SARIF, a skipped one included (scripts/security/lib/common.sh: sec_skip)"
log "$job: $sarif"
