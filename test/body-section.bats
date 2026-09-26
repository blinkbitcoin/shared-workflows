#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/body-section.sh owns the marker-delimited section that both the
# release body (`release-assets.sh append`) and the release PR body
# (`pr-notes.sh`) carry. One implementation, so the two can never disagree
# about what a block looks like or how a stale one is found.
load test_helper

setup() {
  BODY="$BATS_TEST_TMPDIR/body.md"
  NOTES="$BATS_TEST_TMPDIR/notes.txt"
  BLOCK="$BATS_TEST_TMPDIR/block.md"
  printf 'Fixed\n• Close the alerts.\n' > "$NOTES"
}

lib() {
  bash -c '
    set -euo pipefail
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/body-section.sh"
    shift
    "$@"
  ' _ "$REPO_ROOT" "$@"
}

@test "render wraps the heading and the notes in the markers" {
  run lib render_section_block "Store notes" "$NOTES"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  expected="$(printf '\n<!-- workflows:append:Store notes -->\n## Store notes\n\nFixed\n• Close the alerts.\n<!-- /workflows:append:Store notes -->')"
  [ "$output" = "$expected" ] || fail "rendered block differs:
$output"
}

@test "strip removes a marker block wherever it sits and leaves the rest alone" {
  cat > "$BODY" <<'EOF'
## [1.2.3](https://example.test/compare/v1.2.2...v1.2.3)

### Features

- a feature

<!-- workflows:append:Store notes -->
## Store notes

old prose
<!-- /workflows:append:Store notes -->

---
footer
EOF
  run lib strip_section_block "$BODY" "Store notes"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$output" "old prose" || fail "the block survived: $output"
  not_contains "$output" "workflows:append" || fail "a marker survived: $output"
  contains "$output" "- a feature" || fail "content before the block was lost: $output"
  contains "$output" "footer" || fail "content after the block was lost: $output"
}

@test "strip only touches the block with the given title" {
  cat > "$BODY" <<'EOF'
notes

<!-- workflows:append:Production -->
## Production

released
<!-- /workflows:append:Production -->

<!-- workflows:append:Store notes -->
## Store notes

prose
<!-- /workflows:append:Store notes -->
EOF
  run lib strip_section_block "$BODY" "Store notes"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "## Production" || fail "another block was stripped: $output"
  not_contains "$output" "## Store notes" || fail "the block survived: $output"
}

@test "strip migrates a marker-less legacy heading up to the next heading" {
  cat > "$BODY" <<'EOF'
notes

## Store notes

legacy prose

## Production

released
EOF
  run lib strip_section_block "$BODY" "Store notes"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$output" "legacy prose" || fail "the legacy section survived: $output"
  contains "$output" "## Production" || fail "the following section was lost: $output"
}

@test "strip collapses the blank lines a removed block leaves behind" {
  printf 'a\n\n\n\nb\n' > "$BODY"
  run lib strip_section_block "$BODY" "Store notes"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "$(printf 'a\n\nb')" ] || fail "blank run not collapsed: $output"
}

@test "insert puts the block before the closing rule of a release PR body" {
  cat > "$BODY" <<'EOF'
:robot: I have created a release *beep* *boop*
---


## [1.2.3](https://example.test/compare/v1.2.2...v1.2.3) (2026-09-21)


### Bug Fixes

* a fix

---
This PR was generated with Release Please.
EOF
  lib render_section_block "Store notes" "$NOTES" > "$BLOCK"
  run lib insert_before_footer "$BODY" "$BLOCK"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  # The block must sit after the changelog and before the last rule, and the
  # header and footer must be untouched.
  [ "$(printf '%s\n' "$output" | grep -n '^---$' | tail -1 | cut -d: -f1)" -gt \
    "$(printf '%s\n' "$output" | grep -n '^## Store notes$' | cut -d: -f1)" ] \
    || fail "the block is not before the closing rule: $output"
  [ "$(printf '%s\n' "$output" | grep -n '^## Store notes$' | cut -d: -f1)" -gt \
    "$(printf '%s\n' "$output" | grep -n '^\* a fix$' | cut -d: -f1)" ] \
    || fail "the block is not after the changelog: $output"
  [ "$(printf '%s\n' "$output" | head -1)" = ':robot: I have created a release *beep* *boop*' ] \
    || fail "the header changed: $output"
  [ "$(printf '%s\n' "$output" | tail -1)" = 'This PR was generated with Release Please.' ] \
    || fail "the footer changed: $output"
}

@test "insert appends when the body has no closing rule" {
  printf 'Initial release notes.\n' > "$BODY"
  lib render_section_block "Store notes" "$NOTES" > "$BLOCK"
  run lib insert_before_footer "$BODY" "$BLOCK"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(printf '%s\n' "$output" | head -1)" = 'Initial release notes.' ] || fail "body changed: $output"
  [ "$(printf '%s\n' "$output" | tail -1)" = '<!-- /workflows:append:Store notes -->' ] \
    || fail "the block was not appended: $output"
}

@test "a single rule is a heading separator, not a footer, so insert appends" {
  printf 'title\n---\nbody\n' > "$BODY"
  lib render_section_block "Store notes" "$NOTES" > "$BLOCK"
  run lib insert_before_footer "$BODY" "$BLOCK"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(printf '%s\n' "$output" | tail -1)" = '<!-- /workflows:append:Store notes -->' ] \
    || fail "the block was not appended: $output"
}

@test "strip after insert gives the original body back" {
  cat > "$BODY" <<'EOF'
:robot: I have created a release *beep* *boop*
---

## [1.2.3](https://example.test/compare/v1.2.2...v1.2.3) (2026-09-21)

* a fix

---
This PR was generated with Release Please.
EOF
  lib render_section_block "Store notes" "$NOTES" > "$BLOCK"
  lib insert_before_footer "$BODY" "$BLOCK" > "$BATS_TEST_TMPDIR/injected.md"
  run lib strip_section_block "$BATS_TEST_TMPDIR/injected.md" "Store notes"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "$(cat "$BODY")" ] || fail "round trip differs:
--- original ---
$(cat "$BODY")
--- stripped ---
$output"
}

@test "squeeze collapses blank runs and drops trailing blank lines, from a file or stdin" {
  printf 'a\n\n\n\nb\n \n\n' > "$BODY"
  run lib squeeze_blank_lines "$BODY"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "$(printf 'a\n\nb')" ] || fail "not squeezed: $(printf '%s' "$output" | od -c)"
  run bash -c 'source "$1/scripts/lib/body-section.sh"; printf "x\n\n" | squeeze_blank_lines -' _ "$REPO_ROOT"
  [ "$output" = "x" ] || fail "stdin was not squeezed: $(printf '%s' "$output" | od -c)"
}

# pr-notes.sh compares a fetched body with one rebuilt from its stripped copy.
# A body that differs only in a trailing blank line - what `gh pr view --jq`
# returns for a body stored with a final newline - must compare equal.
@test "squeezed, a body with a trailing blank line equals the body built from its stripped copy" {
  printf 'intro\n---\n\n\n## [1.2.3]\n\n* fix\n---\nfooter\n\n' > "$BODY"
  lib strip_section_block "$BODY" "Store notes" > "$BATS_TEST_TMPDIR/stripped"
  run cmp -s "$BODY" "$BATS_TEST_TMPDIR/stripped"
  [ "$status" -ne 0 ] || fail "the raw copies already match, so this case proves nothing"
  run cmp -s <(lib squeeze_blank_lines "$BODY") <(lib squeeze_blank_lines "$BATS_TEST_TMPDIR/stripped")
  [ "$status" -eq 0 ] || fail "the squeezed copies differ"
}
