#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# The section is rendered with body-section.sh, the same code pr-notes.sh uses,
# so a change to how a block looks moves both sides of this check together.
load test_helper

setup() {
  CHECK="$REPO_ROOT/scripts/self/check-rehearsal-section.sh"
  unset SECTION SECTION_TITLE
  printf '• close the alerts\n• speed up launch\n' > "$BATS_TEST_TMPDIR/notes"
}

# render TITLE - the section pr-notes.sh would output for TITLE: the block
# without its leading blank line.
render() {
  bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/body-section.sh"; render_section_block "$2" "$3"' \
    _ "$REPO_ROOT" "$1" "$BATS_TEST_TMPDIR/notes" | sed '1{/^$/d;}'
}

@test "a rendered section passes and is logged" {
  SECTION="$(render 'Store notes')" run bash "$CHECK"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "2 lines of notes" || fail "the count is not logged: $output"
  contains "$output" "• speed up launch" || fail "the section is not logged: $output"
}

@test "a section under another title passes when SECTION_TITLE says so" {
  SECTION="$(render 'What is new')" SECTION_TITLE='What is new' run bash "$CHECK"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  SECTION="$(render 'What is new')" run bash "$CHECK"
  [ "$status" -ne 0 ] || fail "a 'What is new' block passed as the Store notes section"
}

@test "an empty section fails" {
  SECTION='' run bash "$CHECK"
  [ "$status" -ne 0 ] || fail "an empty section passed"
  contains "$output" "section output is empty" || fail "no message: $output"
  run bash "$CHECK"
  [ "$status" -ne 0 ] || fail "an unset section passed"
}

@test "a section without the begin marker fails" {
  SECTION="$(render 'Store notes' | sed 1d)" run bash "$CHECK"
  [ "$status" -ne 0 ] || fail "a section without its begin marker passed"
  contains "$output" "does not open with '<!-- workflows:append:Store notes -->'" || fail "no message: $output"
}

@test "a section without the end marker fails" {
  SECTION="$(render 'Store notes' | sed '$d')" run bash "$CHECK"
  [ "$status" -ne 0 ] || fail "a section without its end marker passed"
  contains "$output" "does not close with '<!-- /workflows:append:Store notes -->'" || fail "no message: $output"
}

@test "a section with markers and no notes fails" {
  : > "$BATS_TEST_TMPDIR/notes"
  SECTION="$(render 'Store notes')" run bash "$CHECK"
  [ "$status" -ne 0 ] || fail "a note-less section passed"
  contains "$output" "carries no notes" || fail "no message: $output"
}
