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
# A dry run is the same work up to the edit, and then no edit: the would-be
# body goes to the job summary instead. With PR_BODY_FILE as well it needs no
# PR and no `gh` at all, which is what lets a repository with no release PR
# open - this one's own CI, a consumer's pull request - run the real workflow.
#
# Usage: pr-notes.sh [PR_NUMBER]
# Env: SECTION_TITLE (default "Store notes");
#      PR_BODY_FILE (a release-please-shaped PR body to read instead of
#        fetching the PR's; a relative path is read from the consumer root);
#      DRY_RUN (`1` or `true`: never edit the PR; `0`, `false` or unset: edit);
#      GH_TOKEN and GH_REPO, only when `gh` is called (a fetch or an edit);
#      plus whatever notes.sh reads (NOTES_LOCALES, the consumer's own
#      variables and keys).
# Out: `section`, the rendered marker-delimited block, in $GITHUB_OUTPUT (on
#      stdout when that is unset), in both modes; in a dry run, the would-be
#      body appended to $GITHUB_STEP_SUMMARY when that is set.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
source "$(dirname "$0")/../lib/body-section.sh"

pr="${1:-}"
title="${SECTION_TITLE:-Store notes}"
body_file="${PR_BODY_FILE:-}"
case "${DRY_RUN:-}" in
  1 | true) dry_run=1 ;;
  '' | 0 | false) dry_run=0 ;;
  *) die "DRY_RUN must be 1, true, 0 or false (got '$DRY_RUN')" ;;
esac

[ -n "$pr" ] || [ -n "$body_file" ] ||
  die "usage: pr-notes.sh PR_NUMBER - no PR number given, and no PR_BODY_FILE to read a body from instead"
[ -n "$pr" ] || [ "$dry_run" -eq 1 ] ||
  die "no PR number given: a body from PR_BODY_FILE alone has no PR to edit, so it needs DRY_RUN=true (the dry-run input)"

# `gh` fetches the body when no file is given and edits it outside a dry run.
# A dry run from a file calls neither, and must not need a token or a CLI it
# never uses: a fork's pull request has no token worth the name.
if [ -z "$body_file" ] || [ "$dry_run" -eq 0 ]; then
  require_cmd gh
  : "${GH_REPO:?GH_REPO not set (owner/name)}"
fi

if [ -n "$pr" ]; then
  subject="release PR $pr"
else
  subject="release PR body $body_file"
fi
[ "$dry_run" -eq 0 ] || log "$subject: dry run - the $title section is generated, and no PR is edited"

tmp="${RUNNER_TEMP:-/tmp}"
fetched="$tmp/pr-notes-body.md"
stripped="$tmp/pr-notes-body-stripped.md"
block="$tmp/pr-notes-block.md"
updated="$tmp/pr-notes-body-updated.md"

group "$subject: read the body"
# CRLF normalised on the way in: GitHub stores what a browser or an API client
# sent, and a `\r` on the closing `---` would hide it from the footer search.
# A file gets the same treatment - it is usually a copy of such a body.
if [ -n "$body_file" ]; then
  case "$body_file" in
    /*) body_path="$body_file" ;;
    *) body_path="$(consumer_root)/$body_file" ;;
  esac
  [ -f "$body_path" ] ||
    die "PR_BODY_FILE '$body_file' does not exist (looked for $body_path; a relative path is read from the consumer's working directory)"
  tr -d '\r' < "$body_path" > "$fetched"
else
  gh pr view "$pr" --repo "$GH_REPO" --json body --jq '.body' | tr -d '\r' > "$fetched"
fi
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

group "$subject: write the $title section"
render_section_block "$title" "$notes" > "$block"
insert_before_footer "$stripped" "$block" > "$updated"
# The block without the blank line that separates it from the changelog: the
# output is the section itself, its markers the first and the last line.
section="$(cat "$block")"
gh_output_multiline section "${section#$'\n'}"
# Like with like: $updated is built from the stripped copy, which has its
# blank lines squeezed, so the body it is compared with is squeezed too. A raw
# compare never matched a real PR (see squeeze_blank_lines). Only the compare
# is normalised; what an edit writes is $updated as built.
if cmp -s <(squeeze_blank_lines "$fetched") <(squeeze_blank_lines "$updated"); then
  unchanged=1
else
  unchanged=0
fi
if [ "$dry_run" -eq 1 ]; then
  if [ "$unchanged" -eq 1 ]; then
    verdict="body unchanged, a real run would not edit it"
  else
    verdict="a real run would edit the body"
  fi
  log "$subject: dry run, not editing - $verdict; the body a real run would write:"
  cat "$updated" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    # Fenced, so the summary shows the markers and the rule lines a reader is
    # checking rather than rendering them away.
    {
      printf '### %s: the body a real run would write (dry run)\n\n' "$subject"
      printf 'Dry run: %s.\n\n' "$verdict"
      printf '````markdown\n'
      cat "$updated"
      printf '````\n'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
elif [ "$unchanged" -eq 1 ]; then
  log "$subject: body unchanged, not editing"
else
  gh pr edit "$pr" --repo "$GH_REPO" --body-file "$updated"
  log "$subject: $title section written ($(wc -l < "$notes" | tr -d ' ') lines)"
fi
endgroup
