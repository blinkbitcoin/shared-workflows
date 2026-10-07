#!/usr/bin/env bash
# Write a short markdown summary (title, artifact link, optional junit
# pass/fail counts) to $GITHUB_STEP_SUMMARY, or stdout when that's unset.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

title="${1:?usage: artifact-summary.sh TITLE [URL] [junit.xml]}"
url="${2:-}"
junit="${3:-}"

if [ -n "$url" ]; then
  summary="## $title

[View artifact]($url)"
else
  summary="## $title

No forensics files were produced."
fi

# A junit path that was never written is the normal shape of a run that died
# before the suite finished (emulator never booted, app-launch timed out, the
# suite hit its bound). This script runs from the `if: always()` forensics step,
# so dying here would fail the very step that carries the diagnosis: warn and
# emit the summary without counts instead.
if [ -n "$junit" ] && [ ! -f "$junit" ]; then
  warn "artifact-summary: no junit file at $junit"
  junit=""
fi

if [ -n "$junit" ]; then
  if command -v yq >/dev/null 2>&1; then
    tests=$(yq -p xml -o json -r '(.testsuites."+@tests" // .testsuite."+@tests") // ""' "$junit")
    failures=$(yq -p xml -o json -r '(.testsuites."+@failures" // .testsuite."+@failures") // "0"' "$junit")
  else
    tests=$(grep -o 'tests="[0-9]*"' "$junit" | head -1 | grep -o '[0-9]*' || true)
    failures=$(grep -o 'failures="[0-9]*"' "$junit" | head -1 | grep -o '[0-9]*' || true)
  fi
  tests="${tests:-0}"
  failures="${failures:-0}"
  passed=$((tests - failures))
  summary="$summary

$passed passed, $failures failed"
fi

gh_summary "$summary"
