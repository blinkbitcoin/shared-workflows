#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# The fallback branch is the one under test: the consumer owns the real
# generator (scripts/release/notes.mjs) and a consumer that ships none must
# still get a usable, non-empty notes bundle - App Store Connect rejects a
# submission whose "what's new" is empty.
load test_helper

setup() {
  ROOT="$BATS_TEST_TMPDIR/app"
  mkdir -p "$ROOT"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" config user.email t@example.test
  git -C "$ROOT" config user.name t
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=app
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_RELEASE_META_DIR="$BATS_TEST_TMPDIR/meta"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_ENV"
  unset RELEASE_BODY_FILE NOTES_LOCALES APP_VERSION APP_BUILD_NUMBER
}

commit() { printf '%s\n' "$1" >> "$ROOT/log.txt"; git -C "$ROOT" add -A; git -C "$ROOT" commit -qm "$1"; }
notes() { run bash "$REPO_ROOT/scripts/release/notes.sh"; }

@test "the fallback writes all three files from the commit subjects, and warns" {
  commit "feat: a feature"
  commit "fix: a fix"
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1042 notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning::" || fail "the fallback did not warn: $output"
  [ "$(cat "$WORKFLOWS_RELEASE_META_DIR/store-notes.json")" = "{}" ] \
    || fail "store-notes.json is not an empty object: $(cat "$WORKFLOWS_RELEASE_META_DIR/store-notes.json")"
  grep -qx -- '- fix: a fix' "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" \
    || fail "the commit subjects are missing: $(cat "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt")"
  grep -qx '## 1.2.3 (1042)' "$WORKFLOWS_RELEASE_META_DIR/notes.md" \
    || fail "notes.md has no version heading: $(cat "$WORKFLOWS_RELEASE_META_DIR/notes.md")"
  grep -q 'a feature' "$WORKFLOWS_RELEASE_META_DIR/notes.md" \
    || fail "notes.md does not carry the notes: $(cat "$WORKFLOWS_RELEASE_META_DIR/notes.md")"
}

@test "the fallback only lists commits since the last v* tag" {
  commit "old: before the tag"
  git -C "$ROOT" tag v1.0.0
  commit "new: after the tag"
  APP_VERSION=1.0.1 APP_BUILD_NUMBER=2 notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q 'after the tag' "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" \
    || fail "the new commit is missing: $(cat "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt")"
  ! grep -q 'before the tag' "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" \
    || fail "a commit from before the tag was included: $(cat "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt")"
}

# An empty "what's new" makes App Store Connect reject the submission, so the
# fallback never ships one - not even when there is nothing to say.
@test "an empty commit range still yields a non-empty notes file" {
  commit "only: this one"
  git -C "$ROOT" tag v1.0.0
  APP_VERSION=1.0.0 APP_BUILD_NUMBER=1 notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -s "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" ] || fail "shipped an empty notes file"
  grep -qx -- '- Bug fixes and improvements' "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" \
    || fail "unexpected fallback content: $(cat "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt")"
}

@test "the fallback publishes RELEASE_NOTES_STORE_FILE for the lanes" {
  commit "feat: a feature"
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1 notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "RELEASE_NOTES_STORE_FILE=$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" "$GITHUB_ENV" \
    || fail "the lanes were not told where the notes are: $(cat "$GITHUB_ENV")"
}

@test "the version heading falls back rather than printing an empty version" {
  commit "feat: a feature"
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx '## unreleased (0)' "$WORKFLOWS_RELEASE_META_DIR/notes.md" \
    || fail "unexpected heading: $(cat "$WORKFLOWS_RELEASE_META_DIR/notes.md")"
}

@test "the consumer's notes.mjs is preferred, and is handed the release body when there is one" {
  mkdir -p "$ROOT/scripts/release"
  cat > "$ROOT/scripts/release/notes.mjs" <<'JS'
import { writeFileSync, mkdirSync } from "node:fs";
const out = process.argv[process.argv.indexOf("--out") + 1];
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/argv.txt`, process.argv.slice(2).join(" ") + "\n");
writeFileSync(`${out}/locales.txt`, (process.env.NOTES_LOCALES ?? "") + "\n");
writeFileSync(`${out}/store-notes.json`, '{"en":{}}\n');
writeFileSync(`${out}/notes-store.txt`, "- from the generator\n");
JS
  printf 'the release body\n' > "$BATS_TEST_TMPDIR/body.md"
  RELEASE_BODY_FILE="$BATS_TEST_TMPDIR/body.md" NOTES_LOCALES='en,de' notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$output" "::warning::consumer has no" || fail "fell back despite a notes.mjs: $output"
  argv="$(cat "$WORKFLOWS_RELEASE_META_DIR/argv.txt")"
  contains "$argv" "--from-body $BATS_TEST_TMPDIR/body.md" || fail "the body was not passed: $argv"
  contains "$argv" "--body-section" || fail "--body-section is missing: $argv"
  [ "$(cat "$WORKFLOWS_RELEASE_META_DIR/locales.txt")" = "en,de" ] || fail "NOTES_LOCALES was not forwarded"
  contains "$argv" "--locales en,de" || fail "the locales were not passed as a flag: $argv"
  # notes.mjs wrote no notes.md, so the script must synthesise one rather than
  # leaving the release body empty.
  [ -f "$WORKFLOWS_RELEASE_META_DIR/notes.md" ] || fail "no notes.md was produced"
}

@test "notes.mjs is used with --from-commits when there is no release body" {
  mkdir -p "$ROOT/scripts/release"
  cat > "$ROOT/scripts/release/notes.mjs" <<'JS'
import { writeFileSync, mkdirSync } from "node:fs";
const out = process.argv[process.argv.indexOf("--out") + 1];
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/argv.txt`, process.argv.slice(2).join(" ") + "\n");
writeFileSync(`${out}/locales.txt`, JSON.stringify(process.env.NOTES_LOCALES ?? null) + "\n");
writeFileSync(`${out}/store-notes.json`, "{}\n");
writeFileSync(`${out}/notes-store.txt`, "- x\n");
JS
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(cat "$WORKFLOWS_RELEASE_META_DIR/argv.txt")"
  contains "$argv" "--from-commits" || fail "unexpected argv: $argv"
  # An empty notes-locales input contributes no flag at all, rather than
  # `--locales ''`, which the generator would read as "no locales".
  not_contains "$argv" "--locales" || fail "an empty NOTES_LOCALES became a flag: $argv"
  # ...and no locale in the environment either: the generator picks them from
  # the app's store metadata. A default filled in here used to win over that.
  [ "$(cat "$WORKFLOWS_RELEASE_META_DIR/locales.txt")" = '""' ] \
    || fail "an empty NOTES_LOCALES reached the generator as $(cat "$WORKFLOWS_RELEASE_META_DIR/locales.txt")"
}

@test "an empty NOTES_LOCALES stays empty on the release-body path too" {
  mkdir -p "$ROOT/scripts/release"
  cat > "$ROOT/scripts/release/notes.mjs" <<'JS'
import { writeFileSync, mkdirSync } from "node:fs";
const out = process.argv[process.argv.indexOf("--out") + 1];
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/argv.txt`, process.argv.slice(2).join(" ") + "\n");
writeFileSync(`${out}/locales.txt`, JSON.stringify(process.env.NOTES_LOCALES ?? null) + "\n");
writeFileSync(`${out}/store-notes.json`, "{}\n");
writeFileSync(`${out}/notes-store.txt`, "- x\n");
JS
  printf 'the release body\n' > "$BATS_TEST_TMPDIR/body.md"
  RELEASE_BODY_FILE="$BATS_TEST_TMPDIR/body.md" notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$WORKFLOWS_RELEASE_META_DIR/argv.txt")" "--from-body" || fail "the body path did not run"
  not_contains "$(cat "$WORKFLOWS_RELEASE_META_DIR/argv.txt")" "--locales" || fail "an empty NOTES_LOCALES became a flag"
  [ "$(cat "$WORKFLOWS_RELEASE_META_DIR/locales.txt")" = '""' ] \
    || fail "an empty NOTES_LOCALES reached the generator as $(cat "$WORKFLOWS_RELEASE_META_DIR/locales.txt")"
}

# notes.mjs is the consumer's code: what it produces is asserted, not trusted.
@test "a notes.mjs that produces nothing is fatal" {
  mkdir -p "$ROOT/scripts/release"
  printf '// writes nothing\n' > "$ROOT/scripts/release/notes.mjs"
  notes
  [ "$status" -ne 0 ] || fail "accepted a generator that produced nothing: $output"
  contains "$output" "produced no store-notes.json" || fail "unexpected message: $output"
}
