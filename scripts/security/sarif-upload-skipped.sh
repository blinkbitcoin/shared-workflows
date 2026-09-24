#!/usr/bin/env bash
# Say out loud that the findings did not reach code scanning.
#
# Usage: sarif-upload-skipped.sh REASON
#
# A pull request from a fork gets a read-only GITHUB_TOKEN whatever the
# workflow's permissions block requests, so the SARIF upload cannot happen. The
# verdict still ran and still blocked or passed on its own findings - the gate is
# not weaker on a fork, only its reporting destination is - and a reader has to
# be told that, or an empty Security tab reads as "scanned, nothing found".
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

reason="${1:?usage: sarif-upload-skipped.sh REASON}"
printf '::warning::Security findings were not uploaded to code scanning: %s. The verdict still applied the threshold - read the job summary and the Verdict step for the findings.\n' "$reason"
{
  printf '\n> Findings were **not** uploaded to code scanning: %s.\n' "$reason"
  printf '> The verdict above still applied the threshold; the findings are in this summary and in the job log.\n'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
