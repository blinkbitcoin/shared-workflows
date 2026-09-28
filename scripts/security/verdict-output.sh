#!/usr/bin/env bash
# Turn the consumer's verdict file into the Verdict job's `verdict` output: the
# value check-security.yml exposes and publish-badges.yml renders the Security
# badge from.
#
# Its own step, after verdict.sh and under !cancelled(), because verdict.sh
# exits 1 when findings block, and the badge needs the verdict most in exactly
# that run.
#
# The rules, in order:
#   a scanner job failed          -> {"verdict":"fail"}: a crashed scanner
#                                    reported nothing, so the merge could read pass
#   the verdict file exists       -> its one line, as it is
#   the Verdict step failed       -> {"verdict":"fail"}: no SARIF, no node, or the
#                                    merge crashed; not a clean run
#   otherwise                     -> no output: this consumer's verdict.mjs
#                                    predates verdict.json, and saying "fail" would lie
#
# Env: SCANNER_FAILED (true|false), VERDICT_OUTCOME (the Verdict step's
# outcome), SECURITY_DIR (default .security).
# CI: the "Verdict output" step of check-security.yml's verdict job.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

root="$(consumer_root)"
file="$root/${SECURITY_DIR:-.security}/verdict.json"
sink="${GITHUB_OUTPUT:-/dev/stdout}"

if [ "${SCANNER_FAILED:-false}" = true ]; then
  log "a scanner job failed, so the verdict output is fail whatever the merge said"
  printf 'verdict={"verdict":"fail"}\n' >> "$sink"
elif [ -f "$file" ]; then
  # One line by construction (verdict.mjs); tr makes sure of it, because a
  # second line would end the output early.
  printf 'verdict=%s\n' "$(tr -d '\r\n' < "$file")" >> "$sink"
elif [ "${VERDICT_OUTCOME:-}" = failure ]; then
  printf 'verdict={"verdict":"fail"}\n' >> "$sink"
else
  log "no $file: this repository's verdict.mjs writes none, so there is no verdict output"
fi
