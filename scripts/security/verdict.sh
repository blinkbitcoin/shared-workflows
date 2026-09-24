#!/usr/bin/env bash
# Merge the scanners' SARIF into one verdict, and put that verdict where it will
# be read: the step log and the run summary.
#
# The merge, the threshold and the exit code are the consumer's verdict.mjs -
# the same file `make check-security` runs - so a green laptop and a green
# pipeline are the same claim. This wrapper decides only where the answer is
# written, and hands the exit code back untouched.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

root="$(consumer_root)"
cd "$root"

merger='scripts/security/verdict.mjs'
[ -f "$merger" ] || die_fix \
  "check-security.yml reached its verdict job, but this repository has no $merger" \
  "add scripts/security/verdict.mjs as the template ships it, or stop calling check-security.yml" \
  "check-securityyml"

out="${SECURITY_DIR:-.security}"
count=0
if [ -d "$out" ]; then
  # wc -l, not `grep -c .`: under `set -o pipefail` an empty match makes the
  # whole substitution fail and leaves `count` empty, and `[ "" -gt 0 ]` then
  # errors instead of reporting. wc always exits 0.
  count="$(find "$out" -maxdepth 1 -type f -name '*.sarif' | wc -l | tr -d ' ')"
fi
# No SARIF at all means every scanner skipped or died. A clean verdict derived
# from nothing is the one outcome this gate must never produce, so it is a
# failure with a message that points at the jobs above rather than at this one.
[ "$count" -gt 0 ] || die "no SARIF files in $out: every scanner job was switched off or failed. Read the scanner jobs above; do not read this run as clean. To turn the gate off, set \"enabled\": false in security-policy.json"

code=0
report="$(node "$merger" "$out" 2>&1)" || code=$?
printf '%s\n' "$report"
{
  printf '## Security\n\n'
  # shellcheck disable=SC2016  # the backticks are a literal markdown code fence, not command substitution
  printf '```\n%s\n```\n' "$report"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
exit "$code"
