#!/usr/bin/env bash
# Hold the consumer rehearsal to what it exists to prove: that
# pr-release-notes.yml, run for real against a consumer, hands back a store
# notes section a release PR could carry.
#
# self-rehearsal.yml runs the workflow in a dry run and passes its `section`
# output here. A run that went green while rendering nothing would be the
# failure this rehearsal was added to catch - a reusable workflow that no gate
# executes - wearing a green check, so an empty, unmarked or note-less section
# fails the job.
#
# Usage: check-rehearsal-section.sh
# Env: SECTION (the workflow's `section` output), SECTION_TITLE (default
#      "Store notes"; the title the rehearsal passed, if any).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/body-section.sh"

title="${SECTION_TITLE:-Store notes}"
section="${SECTION:-}"
[ -n "$section" ] ||
  die "the rehearsal's section output is empty: pr-release-notes.yml rendered no $title section, or its output is no longer wired to the job"

section_markers "$title"
first="$(printf '%s\n' "$section" | head -1)"
last="$(printf '%s\n' "$section" | tail -1)"
[ "$first" = "$begin_marker" ] ||
  die "the section does not open with '$begin_marker' (first line: '$first')"
[ "$last" = "$end_marker" ] ||
  die "the section does not close with '$end_marker' (last line: '$last')"

# Everything but the markers, the heading and blank lines is the notes.
notes="$(printf '%s\n' "$section" | grep -vxF -e "$begin_marker" -e "$end_marker" -e "## $title" | grep -v '^[[:space:]]*$' || true)"
[ -n "$notes" ] || die "the section between '$begin_marker' and '$end_marker' carries no notes"

log "rehearsal section: $(printf '%s\n' "$notes" | wc -l | tr -d ' ') lines of notes between the markers"
printf '%s\n' "$section" >&2
