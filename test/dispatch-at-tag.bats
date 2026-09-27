#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

SCRIPT="$REPO_ROOT/scripts/release/dispatch-at-tag.sh"

# A fake gh: logs one line per call, and fails the call whose workflow is
# FAKE_FAILS.
setup() {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$3" != "${FAKE_FAILS:-}" ] || exit 1
exit 0
EOF
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
  export GH_TOKEN=fake GH_REPO=org/app TAG=v1.2.3
}

@test "each line starts its workflow at the tag, with its fields and {tag} filled in" {
  DISPATCHES=$'cd-beta.yml tag={tag}\nci-web.yml deploy=true' run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GH_LOG")" = $'workflow run cd-beta.yml --repo org/app --ref v1.2.3 -f tag=v1.2.3\nworkflow run ci-web.yml --repo org/app --ref v1.2.3 -f deploy=true' ] \
    || fail "unexpected calls: $(cat "$GH_LOG")"
  contains "$output" "dispatching cd-beta.yml at v1.2.3" || fail "output: $output"
}

@test "blank lines, surrounding space and comment lines are skipped, so marker comments can sit in the list" {
  DISPATCHES=$'\n  cd-beta.yml tag={tag}  \n# init:web-start\n  ci-web.yml\n# init:web-end\n' run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GH_LOG")" = $'workflow run cd-beta.yml --repo org/app --ref v1.2.3 -f tag=v1.2.3\nworkflow run ci-web.yml --repo org/app --ref v1.2.3' ] \
    || fail "unexpected calls: $(cat "$GH_LOG")"
}

@test "a line naming no workflow file fails before anything is started" {
  DISPATCHES=$'cd-beta.yml tag={tag}\ncd-beta tag={tag}' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "accepted a line with no workflow file: $output"
  contains "$output" "not a workflow file: 'cd-beta' in dispatch line 'cd-beta tag={tag}'" || fail "output: $output"
  [ ! -s "$GH_LOG" ] || fail "started something anyway: $(cat "$GH_LOG")"
}

@test "a field that is not key=value fails before anything is started" {
  DISPATCHES='cd-beta.yml tag' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "accepted a bare field: $output"
  contains "$output" "not key=value: 'tag' in dispatch line 'cd-beta.yml tag'" || fail "output: $output"
  [ ! -s "$GH_LOG" ] || fail "started something anyway: $(cat "$GH_LOG")"
}

@test "a list with nothing to start is an error" {
  DISPATCHES=$'# only a comment\n' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "accepted an empty list: $output"
  contains "$output" "DISPATCHES names no workflow to start at v1.2.3" || fail "output: $output"
}

@test "a dispatch that fails fails the step, after the rest were tried" {
  FAKE_FAILS=cd-beta.yml DISPATCHES=$'cd-beta.yml tag={tag}\nci-web.yml deploy=true' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a failed dispatch passed: $output"
  contains "$output" "could not dispatch cd-beta.yml at v1.2.3" || fail "output: $output"
  contains "$output" "one or more follow-on workflows were not started at v1.2.3" || fail "output: $output"
  grep -q '^workflow run ci-web.yml' "$GH_LOG" || fail "the second dispatch was never tried: $(cat "$GH_LOG")"
}

@test "each required variable is named when it is missing" {
  for var in TAG GH_REPO; do
    DISPATCHES='cd-beta.yml' run env -u "$var" bash "$SCRIPT"
    [ "$status" -ne 0 ] || fail "ran without $var: $output"
    contains "$output" "$var not set" || fail "the missing $var was not named: $output"
  done
}
