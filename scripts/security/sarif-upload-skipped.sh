#!/usr/bin/env bash
# Say out loud that the findings did not reach code scanning.
#
# Usage: sarif-upload-skipped.sh [--summary-only] REASON
#
# The verdict still ran and still blocked or passed on its own findings - the
# gate is not weaker without the upload, only its reporting destination is
# missing - and a reader has to be told that, or an empty Security tab reads as
# "scanned, nothing found".
#
# By default the notice is a ::warning:: as well as a summary line: the caller
# switched the upload off, which someone should notice. --summary-only writes
# the summary line alone, for a run that skips the upload by design - a pull
# request, whose findings are the Verdict job's annotations - where the same
# warning on every change would be noise.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

summary_only=false
if [ "${1:-}" = --summary-only ]; then
  summary_only=true
  shift
fi
reason="${1:?usage: sarif-upload-skipped.sh [--summary-only] REASON}"
[ "$summary_only" = true ] || printf '::warning::Security findings were not uploaded to code scanning: %s. The verdict still applied the threshold - read the job summary and the Verdict step for the findings.\n' "$reason"
{
  printf '\n> Findings were **not** uploaded to code scanning: %s.\n' "$reason"
  printf '> The verdict above still applied the threshold; the findings are in this summary and in the job log.\n'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
