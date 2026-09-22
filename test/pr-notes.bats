#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# `gh` is stubbed with a script that serves a PR body out of a file and writes
# `pr edit --body-file` back into it, so the whole round trip - fetch, strip,
# generate, inject, edit - runs without GitHub. The consumer's generator is a
# two-line notes.mjs that turns the body's bullets into notes-store.txt; the
# real one is the consumer's business (scripts/release/notes.sh).
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
  unset NOTES_LOCALES SECTION_TITLE
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_LOG"
[ -f "$WORKFLOWS_TEST_GH_FAILS" ] && { echo "HTTP 403" >&2; exit 1; }
case "$1 $2" in
  "pr view") cat "$WORKFLOWS_TEST_BODY"; exit 0 ;;
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

@test "notes carrying a rule line or a tag are refused before they reach the PR" {
  cat > "$ROOT/scripts/release/notes.mjs" <<'JS'
import { writeFileSync, mkdirSync } from 'node:fs';
const out = process.argv[process.argv.indexOf('--out') + 1];
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/notes-store.txt`, 'Fixed\n---\n<details>x</details>\n');
writeFileSync(`${out}/store-notes.json`, '{}\n');
JS
  pr_notes 53
  [ "$status" -ne 0 ] || fail "exited 0 with a rule line in the notes"
  contains "$output" "::error::" || fail "no error annotation: $output"
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

@test "a missing PR number is an error" {
  pr_notes
  [ "$status" -ne 0 ] || fail "exited 0 without a PR number"
  contains "$output" "PR number" || fail "no usage message: $output"
}
