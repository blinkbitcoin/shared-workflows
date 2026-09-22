# shellcheck shell=bash
# A marker-delimited section in a GitHub body: the release body's
# `## Store notes` / `## Production` blocks (release-assets.sh append) and the
# release PR body's `## Store notes` block (pr-notes.sh) are the same thing,
# so this is the one place that knows how a block looks and how a stale one is
# found. Requires common.sh.
#
# The block is delimited by HTML-comment markers, not by "the heading down to
# the next `## `". The notes routinely *start* with a `## ` heading - notes.sh's
# fallback writes `## <version> (<build>)` and a release-please body starts
# with `## [x.y.z](...)` - so a heading scan stops at the notes' own heading and
# leaves their tail behind, stacking a little more of it on every re-run.
# Markers bound the block regardless of its content.

# section_markers TITLE - sets begin_marker and end_marker for TITLE.
section_markers() {
  begin_marker="<!-- workflows:append:$1 -->"
  end_marker="<!-- /workflows:append:$1 -->"
}

# strip_section_block BODY_FILE TITLE - BODY_FILE without TITLE's block, on
# stdout, with every run of blank lines collapsed to one and trailing blank
# lines dropped (they would otherwise accumulate one pair per re-run).
#
# A body written before the markers existed has no begin marker, so it falls
# back to the old heading scan once; the next block written is marker-delimited
# like any other.
strip_section_block() {
  local body_file="$1" title="$2" begin_marker end_marker
  section_markers "$title"
  {
    if grep -qxF "$begin_marker" "$body_file"; then
      awk -v b="$begin_marker" -v e="$end_marker" '
        $0 == b { skipping = 1; next }
        skipping && $0 == e { skipping = 0; next }
        !skipping { print }
      ' "$body_file"
    else
      awk -v heading="## $title" '
        $0 == heading { skipping = 1; next }
        skipping && /^## / { skipping = 0 }
        !skipping { print }
      ' "$body_file"
    fi
  } | awk 'BEGIN { blank = 0 }
    /^[[:space:]]*$/ { blank++; next }
    { if (blank > 0) print ""; blank = 0; print }
  '
}

# render_section_block TITLE NOTES_FILE - the block for TITLE, on stdout: one
# leading blank line, the begin marker, the heading, a blank line, the notes,
# the end marker.
render_section_block() {
  local title="$1" notes_file="$2" begin_marker end_marker
  section_markers "$title"
  printf '\n%s\n%s\n\n' "$begin_marker" "## $title"
  cat "$notes_file"
  printf '%s\n' "$end_marker"
}

# insert_before_footer BODY_FILE BLOCK_FILE - BODY_FILE with BLOCK_FILE
# inserted before the closing `---` of a release-please PR body, on stdout.
#
# release-please takes the release notes from between the first and the last
# line that is exactly `---` (`PullRequestBody.parse`), so a block placed
# before the last one reaches the GitHub release body verbatim. A body with
# fewer than two such lines has no footer, and the block is appended.
insert_before_footer() {
  local body_file="$1" block_file="$2" first last
  first="$(grep -nx -- '---' "$body_file" | head -1 | cut -d: -f1 || true)"
  last="$(grep -nx -- '---' "$body_file" | tail -1 | cut -d: -f1 || true)"
  if [ -n "$first" ] && [ -n "$last" ] && [ "$last" -gt "$first" ]; then
    head -n "$((last - 1))" "$body_file"
    cat "$block_file"
    printf '\n'
    tail -n "+$last" "$body_file"
  else
    cat "$body_file"
    cat "$block_file"
  fi
}
