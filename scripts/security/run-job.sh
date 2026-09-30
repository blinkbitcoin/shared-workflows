#!/usr/bin/env bash
# Run one of the security runners beside this script against the consumer, and
# insist it reported.
#
# Usage: run-job.sh JOB
#
# The runners are this family's, not the consumer's: a consumer keeps only its
# settings (security-settings.json) and the files they name. The same runners
# ship in @blinkbitcoin/app-tooling, so `check-security` on a laptop runs what
# this job runs.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

job="${1:?usage: run-job.sh JOB}"
# The nine jobs by name, never a path: a job is how the workflow names a
# runner, and anything else beside this script (a bridge, lib/runner) is not one.
case "$job" in
  dependencies | code | policy | sbom | bundle | mobile | binaries | review | review-codebase) ;;
  *) die "not a security job: $job (expected one of dependencies, code, policy, sbom, bundle, mobile, binaries, review, review-codebase)" ;;
esac
runner="$(cd "$(dirname "$0")" && pwd -P)/$job.sh"
root="$(consumer_root)"
cd "$root"

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
[ -s "$sarif" ] || die "$job.sh exited 0 but left no $sarif. Every runner writes exactly one SARIF, a skipped one included (scripts/security/lib/runner.sh: sec_skip)"
log "$job: $sarif"
