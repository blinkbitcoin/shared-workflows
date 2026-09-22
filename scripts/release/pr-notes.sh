#!/usr/bin/env bash
# Draft the store release notes into a release PR body, once, for a human to
# review before the release is cut.
#
# release-please takes the GitHub release body from the text between the first
# and the last `---` line of the merged PR body, so a `## <title>` block
# placed before the closing rule reaches the release verbatim - and the
# release lanes already read that section back (`notes.mjs --body-section`).
# release-please rewrites the whole PR body on every push to main, so this
# runs on every push too, and strips its own previous block before generating:
# a stale draft never feeds the next one.
#
# The notes themselves are the consumer's business: this hands the stripped
# body to notes.sh as RELEASE_BODY_FILE, which runs the consumer's
# scripts/release/notes.mjs (or its own commit-subject fallback) and leaves
# notes-store.txt in $WORKFLOWS_RELEASE_META_DIR. That file is the section.
#
# Usage: pr-notes.sh PR_NUMBER
# Env: GH_TOKEN, GH_REPO, SECTION_TITLE (default "Store notes"), plus whatever
#      notes.sh reads (NOTES_LOCALES, the consumer's own variables and keys).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
source "$(dirname "$0")/../lib/body-section.sh"
require_cmd gh
: "${GH_REPO:?GH_REPO not set (owner/name)}"

pr="${1:-}"
[ -n "$pr" ] || die "usage: pr-notes.sh PR_NUMBER - no PR number given"
title="${SECTION_TITLE:-Store notes}"

tmp="${RUNNER_TEMP:-/tmp}"
fetched="$tmp/pr-notes-body.md"
stripped="$tmp/pr-notes-body-stripped.md"
block="$tmp/pr-notes-block.md"
updated="$tmp/pr-notes-body-updated.md"

group "release PR $pr: fetch the body"
# CRLF normalised on the way in: GitHub stores what a browser or an API client
# sent, and a `\r` on the closing `---` would hide it from the footer search.
gh pr view "$pr" --repo "$GH_REPO" --json body --jq '.body' | tr -d '\r' > "$fetched"
strip_section_block "$fetched" "$title" > "$stripped"
endgroup

# notes.sh generates from RELEASE_BODY_FILE when it is set (the changelog the
# PR carries), through the consumer's generator or the fallback.
RELEASE_BODY_FILE="$stripped" bash "$(dirname "$0")/notes.sh"
notes="$WORKFLOWS_RELEASE_META_DIR/notes-store.txt"
[ -s "$notes" ] || die "notes.sh left no notes-store.txt in $WORKFLOWS_RELEASE_META_DIR"

# A line of dashes is where release-please splits the body, and a tag is
# parsed by GitHub or by the shared workflow rather than read by a person; a
# section carrying either would change how the release body is built.
! grep -qE '^[[:space:]]*-{3,}[[:space:]]*$' "$notes" \
  || die "the generated notes contain a line of dashes, which would split the release PR body"
! grep -qiE '<[a-z!/]' "$notes" \
  || die "the generated notes contain an HTML tag or comment"

group "release PR $pr: write the $title section"
render_section_block "$title" "$notes" > "$block"
insert_before_footer "$stripped" "$block" > "$updated"
if cmp -s "$fetched" "$updated"; then
  log "release PR $pr: body unchanged, not editing"
else
  gh pr edit "$pr" --repo "$GH_REPO" --body-file "$updated"
  log "release PR $pr: $title section written ($(wc -l < "$notes" | tr -d ' ') lines)"
fi
endgroup
