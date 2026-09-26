#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# `gh` is stubbed with a script that serves a PR body out of a file and writes
# `pr edit --body-file` back into it, so the whole round trip - fetch, strip,
# generate, inject, edit - runs without GitHub. The consumer's generator is a
# two-line notes.mjs that turns the body's bullets into notes-store.txt; the
# real one is the consumer's business (scripts/release/notes.sh).
#
# A dry run from a body file must not touch `gh` at all, so those cases arm
# the stub to fail and then assert that its call log stayed empty.
load test_helper

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  ROOT="$BATS_TEST_TMPDIR/app"
  mkdir -p "$STUB" "$ROOT/scripts/release"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/gh.log"
  export WORKFLOWS_TEST_BODY="$BATS_TEST_TMPDIR/pr-body.md"
  export WORKFLOWS_TEST_GH_FAILS="$BATS_TEST_TMPDIR/gh-fails"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=app
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_RELEASE_META_DIR="$BATS_TEST_TMPDIR/meta"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  export GH_TOKEN=fake GH_REPO=acme/app
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_ENV"
  : > "$WORKFLOWS_TEST_LOG"
  unset NOTES_LOCALES SECTION_TITLE PR_BODY_FILE DRY_RUN
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
[ -f "$WORKFLOWS_TEST_GH_FAILS" ] && { echo "HTTP 403" >&2; exit 1; }
case "$1 $2" in
  # `gh pr view --jq .body` prints the body and then a newline of its own, so
  # a stored body that ends in a newline reads back ending in a blank line.
  "pr view") cat "$WORKFLOWS_TEST_BODY"; echo; exit 0 ;;
  "pr edit")
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && { cp "$2" "$WORKFLOWS_TEST_BODY"; exit 0; }
      shift
    done
    echo "no --body-file" >&2; exit 1 ;;
esac
echo "unexpected gh $*" >&2; exit 1
SH
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH"
  # The consumer's generator: every markdown bullet becomes a notes line, so
  # the test can see exactly which bullets the script fed it.
  cat > "$ROOT/scripts/release/notes.mjs" <<'JS'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
const args = process.argv.slice(2);
const body = readFileSync(args[args.indexOf('--from-body') + 1], 'utf8');
const out = args[args.indexOf('--out') + 1];
const lines = body.split('\n').filter((l) => /^\* /.test(l)).map((l) => `• ${l.slice(2)}`);
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/notes-store.txt`, `${lines.join('\n') || 'Bug fixes and improvements.'}\n`);
writeFileSync(`${out}/store-notes.json`, '{}\n');
JS
  cat > "$WORKFLOWS_TEST_BODY" <<'EOF'
:robot: I have created a release *beep* *boop*
---


## [1.2.3](https://example.test/compare/v1.2.2...v1.2.3) (2026-09-21)


### Bug Fixes

* close the alerts

---
This PR was generated with Release Please.
EOF
}

pr_notes() { run bash "$REPO_ROOT/scripts/release/pr-notes.sh" "$@"; }
edits() { grep -c '^pr edit' "$WORKFLOWS_TEST_LOG" || true; }

# output_value KEY FILE - the value of KEY in a $GITHUB_OUTPUT file written in
# the heredoc delimiter form, and nothing when KEY is not there.
output_value() {
  awk -v key="$1" '
    !inside && index($0, key "<<") == 1 { delim = substr($0, length(key) + 3); inside = 1; next }
    inside && $0 == delim { exit }
    inside { print }
  ' "$2"
}

# The section a run over the default body renders, byte for byte.
EXPECTED_SECTION='<!-- workflows:append:Store notes -->
## Store notes

• close the alerts
<!-- /workflows:append:Store notes -->'

# A dry run from a body file, with gh armed to fail and no GH_REPO to read.
dry_run_from_file() {
  : > "$WORKFLOWS_TEST_GH_FAILS"
  cp "$WORKFLOWS_TEST_BODY" "$ROOT/release-body.md"
  unset GH_REPO GH_TOKEN
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  PR_BODY_FILE=release-body.md DRY_RUN=true pr_notes "$@"
}

@test "the generated notes land in a marker block before the closing rule" {
  pr_notes 53
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  body="$(cat "$WORKFLOWS_TEST_BODY")"
  contains "$body" "<!-- workflows:append:Store notes -->
## Store notes

• close the alerts
<!-- /workflows:append:Store notes -->" || fail "no block in: $body"
  [ "$(grep -n '^---$' "$WORKFLOWS_TEST_BODY" | tail -1 | cut -d: -f1)" -gt \
    "$(grep -n '^## Store notes$' "$WORKFLOWS_TEST_BODY" | cut -d: -f1)" ] \
    || fail "the block is after the closing rule: $body"
  [ "$(tail -1 "$WORKFLOWS_TEST_BODY")" = 'This PR was generated with Release Please.' ] \
    || fail "the footer changed: $body"
  grep -q '^pr view 53 --repo acme/app --json body' "$WORKFLOWS_TEST_LOG" || fail "the body was not fetched: $(cat "$WORKFLOWS_TEST_LOG")"
  grep -q '^pr edit 53 --repo acme/app --body-file' "$WORKFLOWS_TEST_LOG" || fail "the body was not written: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a second run is a no-op that does not edit the PR" {
  pr_notes 53
  [ "$status" -eq 0 ] || fail "first run exited $status: $output"
  first="$(cat "$WORKFLOWS_TEST_BODY")"
  pr_notes 53
  [ "$status" -eq 0 ] || fail "second run exited $status: $output"
  [ "$(cat "$WORKFLOWS_TEST_BODY")" = "$first" ] || fail "the body changed on re-run: $(cat "$WORKFLOWS_TEST_BODY")"
  [ "$(edits)" -eq 1 ] || fail "expected one edit, saw $(edits): $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "unchanged" || fail "the no-op was not logged: $output"
}

# The real shape of a release PR on a re-run: GitHub stored the body with a
# final newline, and gh adds its own, so the fetched copy ends in "\n\n" while
# the rebuilt one ends in "\n". Compared raw, those never matched and every
# run edited a PR whose block was already current.
@test "a current block in a body that reads back with a trailing blank line is not edited" {
  pr_notes 53
  [ "$status" -eq 0 ] || fail "first run exited $status: $output"
  printf '\n' >> "$WORKFLOWS_TEST_BODY"
  [ "$(tail -c 2 "$WORKFLOWS_TEST_BODY" | od -An -c | tr -d ' ')" = '\n\n' ] \
    || fail "the fixture does not end in a blank line: $(od -c "$WORKFLOWS_TEST_BODY" | tail -3)"
  pr_notes 53
  [ "$status" -eq 0 ] || fail "second run exited $status: $output"
  contains "$output" "body unchanged" || fail "the no-op was not logged: $output"
  [ "$(edits)" -eq 1 ] || fail "expected only the first run's edit, saw $(edits): $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a dry run reports an unchanged body the same way" {
  pr_notes 53
  [ "$status" -eq 0 ] || fail "first run exited $status: $output"
  printf '\n' >> "$WORKFLOWS_TEST_BODY"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  DRY_RUN=true pr_notes 53
  [ "$status" -eq 0 ] || fail "dry run exited $status: $output"
  contains "$output" "body unchanged" || fail "the dry run did not report the no-op: $output"
  contains "$(cat "$GITHUB_STEP_SUMMARY")" "body unchanged" || fail "the summary does not say unchanged: $(cat "$GITHUB_STEP_SUMMARY")"
  [ "$(edits)" -eq 1 ] || fail "expected only the first run's edit, saw $(edits): $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a dry run says when a real run would edit" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  DRY_RUN=true pr_notes 53
  [ "$status" -eq 0 ] || fail "dry run exited $status: $output"
  contains "$output" "a real run would edit the body" || fail "the dry run did not report the edit: $output"
  not_contains "$output" "body unchanged" || fail "a body without the block was reported unchanged: $output"
  contains "$(cat "$GITHUB_STEP_SUMMARY")" "a real run would edit the body" || fail "the summary does not say so: $(cat "$GITHUB_STEP_SUMMARY")"
}

@test "a previous run's block never feeds the generator" {
  pr_notes 53
  [ "$status" -eq 0 ] || fail "first run exited $status: $output"
  # release-please rewrote the changelog; the old block is still in the body.
  sed -i.bak 's/\* close the alerts/* close the alerts\n* speed up launch/' "$WORKFLOWS_TEST_BODY"
  pr_notes 53
  [ "$status" -eq 0 ] || fail "second run exited $status: $output"
  body="$(cat "$WORKFLOWS_TEST_BODY")"
  [ "$(grep -c '^## Store notes$' "$WORKFLOWS_TEST_BODY")" -eq 1 ] || fail "the block stacked: $body"
  contains "$body" "• speed up launch" || fail "the new bullet is missing: $body"
  [ "$(grep -c '• close the alerts' "$WORKFLOWS_TEST_BODY")" -eq 1 ] || fail "the old prose was fed back in: $body"
}

@test "windows line endings in the fetched body are normalised" {
  sed -i.bak $'s/$/\r/' "$WORKFLOWS_TEST_BODY"
  pr_notes 53
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  ! grep -q $'\r' "$WORKFLOWS_TEST_BODY" || fail "carriage returns survived"
  [ "$(grep -c '^## Store notes$' "$WORKFLOWS_TEST_BODY")" -eq 1 ] || fail "no block: $(cat "$WORKFLOWS_TEST_BODY")"
}

# generator_writes TEXT - replace the consumer's generator with one that
# writes TEXT as notes-store.txt, whatever the body says.
generator_writes() {
  cat > "$ROOT/scripts/release/notes.mjs" <<JS
import { writeFileSync, mkdirSync } from 'node:fs';
const out = process.argv[process.argv.indexOf('--out') + 1];
mkdirSync(out, { recursive: true });
writeFileSync(\`\${out}/notes-store.txt\`, '$1');
writeFileSync(\`\${out}/store-notes.json\`, '{}\\n');
JS
}

@test "notes carrying a rule line are refused before they reach the PR" {
  generator_writes 'Fixed\n---\nMore\n'
  pr_notes 53
  [ "$status" -ne 0 ] || fail "exited 0 with a rule line in the notes"
  contains "$output" "::error::" || fail "no error annotation: $output"
  contains "$output" "line of dashes" || fail "refused for another reason: $output"
  [ "$(edits)" -eq 0 ] || fail "the PR was edited anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

# No rule line here: with one, the dashes check fires first and this branch
# would go untested.
@test "notes carrying an HTML tag are refused before they reach the PR" {
  generator_writes 'Fixed\n<details>x</details>\n'
  pr_notes 53
  [ "$status" -ne 0 ] || fail "exited 0 with a tag in the notes"
  contains "$output" "HTML tag or comment" || fail "refused for another reason: $output"
  [ "$(edits)" -eq 0 ] || fail "the PR was edited anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

# notes.sh asserts the file exists; an empty one would still be a section
# with no notes in it, and an empty store text is rejected by App Store Connect.
@test "an empty notes-store.txt is an error, not an empty section" {
  generator_writes ''
  pr_notes 53
  [ "$status" -ne 0 ] || fail "exited 0 with empty notes"
  contains "$output" "left no notes-store.txt" || fail "refused for another reason: $output"
  [ "$(edits)" -eq 0 ] || fail "the PR was edited anyway: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a consumer without a generator gets the commit-subject fallback" {
  rm "$ROOT/scripts/release/notes.mjs"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" config user.email t@example.test
  git -C "$ROOT" config user.name t
  git -C "$ROOT" commit -q --allow-empty -m "feat: a feature"
  pr_notes 53
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning::" || fail "the fallback did not warn: $output"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "- feat: a feature" || fail "no fallback notes in: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "the section title is configurable" {
  SECTION_TITLE='What is new' pr_notes 53
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qxF '<!-- workflows:append:What is new -->' "$WORKFLOWS_TEST_BODY" || fail "no titled block: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "a gh failure fails the script" {
  : > "$WORKFLOWS_TEST_GH_FAILS"
  pr_notes 53
  [ "$status" -ne 0 ] || fail "exited 0 although gh failed"
}

@test "a missing PR number and a missing body file is an error" {
  pr_notes
  [ "$status" -ne 0 ] || fail "exited 0 without a PR number"
  contains "$output" "PR number" || fail "no usage message: $output"
  contains "$output" "PR_BODY_FILE" || fail "the message does not name the alternative: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "gh was called: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "a dry run with no PR number and no body file is still an error" {
  DRY_RUN=true pr_notes
  [ "$status" -ne 0 ] || fail "exited 0 with nothing to read a body from"
  contains "$output" "PR_BODY_FILE" || fail "no usage message: $output"
}

# --- dry run and body file -------------------------------------------------

@test "a dry run from a body file calls no gh, needs no GH_REPO, and writes the section and the summary" {
  dry_run_from_file
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "gh was called: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$output" "dry run" || fail "the run does not say it is a dry run: $output"
  [ "$(output_value section "$GITHUB_OUTPUT")" = "$EXPECTED_SECTION" ] \
    || fail "section output is not the block: $(cat "$GITHUB_OUTPUT")"
  head -1 "$GITHUB_OUTPUT" | grep -q '^section<<__workflows_eof_[0-9]*$' \
    || fail "the output is not in the heredoc delimiter form: $(cat "$GITHUB_OUTPUT")"
  summary="$(cat "$GITHUB_STEP_SUMMARY")"
  contains "$summary" "(dry run)" || fail "the summary does not say dry run: $summary"
  contains "$summary" "$EXPECTED_SECTION" || fail "the summary has no block: $summary"
  contains "$summary" "This PR was generated with Release Please." || fail "the summary is not the whole body: $summary"
  [ "$(grep -n '^---$' "$GITHUB_STEP_SUMMARY" | tail -1 | cut -d: -f1)" -gt \
    "$(grep -n '^## Store notes$' "$GITHUB_STEP_SUMMARY" | cut -d: -f1)" ] \
    || fail "the block is after the closing rule in the summary: $summary"
}

@test "a dry run reads the body file from the consumer's working directory, not the caller's" {
  cd "$BATS_TEST_TMPDIR"
  dry_run_from_file
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -n "$(output_value section "$GITHUB_OUTPUT")" ] || fail "no section output: $(cat "$GITHUB_OUTPUT")"
}

@test "a dry run with a PR number fetches the body and never edits it" {
  before="$(cat "$WORKFLOWS_TEST_BODY")"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  DRY_RUN=1 pr_notes 53
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q '^pr view 53 --repo acme/app --json body' "$WORKFLOWS_TEST_LOG" || fail "the body was not fetched: $(cat "$WORKFLOWS_TEST_LOG")"
  [ "$(edits)" -eq 0 ] || fail "a dry run edited the PR: $(cat "$WORKFLOWS_TEST_LOG")"
  [ "$(cat "$WORKFLOWS_TEST_BODY")" = "$before" ] || fail "the PR body changed: $(cat "$WORKFLOWS_TEST_BODY")"
  [ "$(output_value section "$GITHUB_OUTPUT")" = "$EXPECTED_SECTION" ] || fail "no section output: $(cat "$GITHUB_OUTPUT")"
  contains "$(cat "$GITHUB_STEP_SUMMARY")" "release PR 53" || fail "the summary does not name the PR: $(cat "$GITHUB_STEP_SUMMARY")"
}

@test "a dry run without GITHUB_STEP_SUMMARY still succeeds and logs the body" {
  : > "$WORKFLOWS_TEST_GH_FAILS"
  cp "$WORKFLOWS_TEST_BODY" "$ROOT/release-body.md"
  PR_BODY_FILE=release-body.md DRY_RUN=true pr_notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "This PR was generated with Release Please." || fail "the would-be body is not in the log: $output"
  # With no $GITHUB_OUTPUT the output goes to stdout, as gh_output does.
  contains "$output" "section<<__workflows_eof_" || fail "the section output is not on stdout: $output"
}

@test "a real run writes the section output too, and no summary" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  : > "$GITHUB_STEP_SUMMARY"
  pr_notes 53
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(edits)" -eq 1 ] || fail "expected one edit: $(cat "$WORKFLOWS_TEST_LOG")"
  [ "$(output_value section "$GITHUB_OUTPUT")" = "$EXPECTED_SECTION" ] || fail "no section output: $(cat "$GITHUB_OUTPUT")"
  [ ! -s "$GITHUB_STEP_SUMMARY" ] || fail "a real run wrote the dry-run summary: $(cat "$GITHUB_STEP_SUMMARY")"
  not_contains "$output" "dry run" || fail "a real run calls itself a dry run: $output"
}

@test "an unchanged body still writes the section output" {
  pr_notes 53
  [ "$status" -eq 0 ] || fail "first run exited $status: $output"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  pr_notes 53
  [ "$status" -eq 0 ] || fail "second run exited $status: $output"
  contains "$output" "unchanged" || fail "the second run was not a no-op: $output"
  [ "$(output_value section "$GITHUB_OUTPUT")" = "$EXPECTED_SECTION" ] || fail "no section output: $(cat "$GITHUB_OUTPUT")"
}

@test "a body file with a PR number and no dry run edits that PR from the file, without fetching it" {
  body="$BATS_TEST_TMPDIR/given-body.md"
  cp "$WORKFLOWS_TEST_BODY" "$body"
  : > "$WORKFLOWS_TEST_BODY"
  PR_BODY_FILE="$body" pr_notes 53
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  ! grep -q '^pr view' "$WORKFLOWS_TEST_LOG" || fail "the PR was fetched although a body file was given: $(cat "$WORKFLOWS_TEST_LOG")"
  [ "$(edits)" -eq 1 ] || fail "expected one edit: $(cat "$WORKFLOWS_TEST_LOG")"
  contains "$(cat "$WORKFLOWS_TEST_BODY")" "$EXPECTED_SECTION" || fail "the edit is not the file plus the block: $(cat "$WORKFLOWS_TEST_BODY")"
}

@test "a body file without a PR number is an error outside a dry run" {
  cp "$WORKFLOWS_TEST_BODY" "$ROOT/release-body.md"
  PR_BODY_FILE=release-body.md pr_notes
  [ "$status" -ne 0 ] || fail "exited 0 with no PR to edit"
  contains "$output" "DRY_RUN=true" || fail "the message does not say how to fix it: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "gh was called: $(cat "$WORKFLOWS_TEST_LOG")"
  DRY_RUN=false PR_BODY_FILE=release-body.md pr_notes
  [ "$status" -ne 0 ] || fail "exited 0 with DRY_RUN=false and no PR to edit"
}

@test "a body file that does not exist is an error" {
  PR_BODY_FILE=missing.md DRY_RUN=true pr_notes
  [ "$status" -ne 0 ] || fail "exited 0 with a missing body file"
  contains "$output" "missing.md" || fail "the message does not name the file: $output"
  contains "$output" "working directory" || fail "the message does not say where relative paths are read from: $output"
}

@test "windows line endings in a body file are normalised" {
  sed -i.bak $'s/$/\r/' "$WORKFLOWS_TEST_BODY"
  dry_run_from_file
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  ! grep -q $'\r' "$GITHUB_STEP_SUMMARY" || fail "carriage returns survived into the body"
  [ "$(output_value section "$GITHUB_OUTPUT")" = "$EXPECTED_SECTION" ] || fail "the block moved: $(cat "$GITHUB_STEP_SUMMARY")"
}

@test "a DRY_RUN that is not a boolean is an error, not a real run" {
  DRY_RUN=yes pr_notes 53
  [ "$status" -ne 0 ] || fail "exited 0 with DRY_RUN=yes"
  contains "$output" "DRY_RUN must be" || fail "no message: $output"
  [ ! -s "$WORKFLOWS_TEST_LOG" ] || fail "gh was called: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "outside a dry run gh and GH_REPO are still required" {
  unset GH_REPO
  pr_notes 53
  [ "$status" -ne 0 ] || fail "exited 0 without GH_REPO"
  contains "$output" "GH_REPO" || fail "no message: $output"
}
