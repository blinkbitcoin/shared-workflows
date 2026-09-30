#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# gen-store-notes.sh runs @blinkbitcoin/app-tooling's gen-store-notes program from this
# checkout in the consumer's directory. Most cases run the real generator, so
# what reaches the lanes is asserted end to end; the ones about the exact
# arguments and environment it is handed, or about what happens when it
# produces nothing, put a fake `node` on PATH that records its call.
# packages/app-tooling/store-notes.test.mjs covers the generator itself.
load test_helper

setup() {
  ROOT="$BATS_TEST_TMPDIR/app"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$ROOT" "$STUB"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" config user.email t@example.test
  git -C "$ROOT" config user.name t
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=app
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  export WORKFLOWS_RELEASE_META_DIR="$BATS_TEST_TMPDIR/meta"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_ENV"
  # Nothing from the developer's shell: a provider exported there would send
  # these cases to a model.
  unset RELEASE_BODY_FILE STORE_NOTES_LOCALES STORE_NOTES_LLM_PROVIDER STORE_NOTES_LLM_EFFORT \
    STORE_NOTES_INCLUDE_CHANGELOG
}

commit() { git -C "$ROOT" commit -q --allow-empty -m "$1"; }
notes() { run bash "$REPO_ROOT/scripts/release/gen-store-notes.sh"; }
meta() { cat "$WORKFLOWS_RELEASE_META_DIR/$1"; }
# json EXPRESSION - EXPRESSION over store-notes.json, bound as `notes`, printed.
json() {
  node -e 'const notes = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(eval(process.argv[2]))' \
    "$WORKFLOWS_RELEASE_META_DIR/store-notes.json" "$1"
}

# fake_node [writes|nothing] - a `node` that records its arguments and
# STORE_NOTES_LOCALES, and writes both files the lanes need unless told not to.
fake_node() {
  cat > "$STUB/node" <<SH
#!/usr/bin/env bash
out=""
prev=""
for arg in "\$@"; do [ "\$prev" = --out ] && out="\$arg"; prev="\$arg"; done
mkdir -p "\$out"
printf '%s\n' "\$*" > "$BATS_TEST_TMPDIR/argv.txt"
printf '%s\n' "\${STORE_NOTES_LOCALES-unset}" > "$BATS_TEST_TMPDIR/locales.txt"
[ "${1:-writes}" = nothing ] && exit 0
printf '{}\n' > "\$out/store-notes.json"
printf 'from the fake\n' > "\$out/store-notes.txt"
SH
  chmod +x "$STUB/node"
  export PATH="$STUB:$PATH"
}

@test "commit subjects since the last v* tag become grouped store notes, in all three files" {
  commit "feat: before the tag"
  git -C "$ROOT" tag v1.0.0
  commit "feat(home): a feature (#12)"
  commit "fix: a fix"
  commit "chore(deps): bump something"
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$output" "::warning::" || fail "warned without a reason: $output"
  contains "$output" "running gen-store-notes --from-commits" || fail "the commit path did not run: $output"
  [ "$(meta store-notes.txt)" = "$(printf 'New\n• A feature.\n\nFixed\n• A fix.')" ] \
    || fail "unexpected notes: $(meta store-notes.txt)"
  [ "$(meta release-notes.md)" = "$(meta store-notes.txt)" ] || fail "release-notes.md is not the notes: $(meta release-notes.md)"
  [ "$(json 'Object.keys(notes).sort().join()')" = "en-US" ] \
    || fail "store-notes.json does not have en-US alone: $(meta store-notes.json)"
  [ "$(json 'notes["en-US"].play')" = "$(meta store-notes.txt)" ] \
    || fail "store-notes.json disagrees with store-notes.txt: $(meta store-notes.json)"
}

# An empty "what's new" makes App Store Connect reject the submission, so the
# notes are never empty - not even when there is nothing to say.
@test "an empty commit range still yields a non-empty notes file" {
  commit "feat: only this one"
  git -C "$ROOT" tag v1.0.0
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(meta store-notes.txt)" = "Bug fixes and improvements." ] || fail "unexpected notes: $(meta store-notes.txt)"
}

@test "the lanes are told where the notes are through STORE_NOTES_FILE" {
  commit "feat: a feature"
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "STORE_NOTES_FILE=$WORKFLOWS_RELEASE_META_DIR/store-notes.txt" "$GITHUB_ENV" \
    || fail "the lanes were not told where the notes are: $(cat "$GITHUB_ENV")"
}

@test "a release body's Store notes section is shipped as written, for every locale asked for" {
  cp "$REPO_ROOT/packages/app-tooling/fixtures/store-notes/release-body.md" "$BATS_TEST_TMPDIR/body.md"
  RELEASE_BODY_FILE="$BATS_TEST_TMPDIR/body.md" STORE_NOTES_LOCALES='en-US,de-DE' notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "running gen-store-notes --from-body --body-section" || fail "the body path did not run: $output"
  contains "$(meta store-notes.txt)" "Signing in sticks now" || fail "the section was not used: $(meta store-notes.txt)"
  [ "$(json 'Object.keys(notes).sort().join()')" = "de-DE,en-US" ] \
    || fail "STORE_NOTES_LOCALES did not decide the locales: $(meta store-notes.json)"
}

@test "with no STORE_NOTES_LOCALES the locales are the app's own store metadata directories" {
  mkdir -p "$ROOT/fastlane/metadata/ios/en-US" "$ROOT/fastlane/metadata/ios/sv-SE" "$ROOT/fastlane/metadata/ios/review_information"
  commit "feat: a feature"
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(json 'Object.keys(notes).sort().join()')" = "en-US,sv-SE" ] \
    || fail "the app's metadata locales were not used: $(meta store-notes.json)"
}

@test "the locales are handed over as a flag and in the environment, and a release body with --body-section" {
  fake_node
  printf 'the release body\n' > "$BATS_TEST_TMPDIR/body.md"
  RELEASE_BODY_FILE="$BATS_TEST_TMPDIR/body.md" STORE_NOTES_LOCALES='en,de' notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  argv="$(cat "$BATS_TEST_TMPDIR/argv.txt")"
  contains "$argv" "$REPO_ROOT/packages/app-tooling/bin/gen-store-notes.mjs --from-body $BATS_TEST_TMPDIR/body.md --body-section" \
    || fail "the package's generator was not run on the body: $argv"
  contains "$argv" "--locales en,de" || fail "the locales were not passed as a flag: $argv"
  contains "$argv" "--out $WORKFLOWS_RELEASE_META_DIR" || fail "--out is not the release-meta directory: $argv"
  [ "$(cat "$BATS_TEST_TMPDIR/locales.txt")" = "en,de" ] || fail "STORE_NOTES_LOCALES was not forwarded"
  # The generator wrote no release-notes.md, so the script makes one rather than
  # leaving the release body empty.
  [ "$(meta release-notes.md)" = "from the fake" ] || fail "no release-notes.md was produced"
}

@test "an empty STORE_NOTES_LOCALES stays empty on both paths, in the flag and in the environment" {
  fake_node
  printf 'the release body\n' > "$BATS_TEST_TMPDIR/body.md"
  for body in "" "$BATS_TEST_TMPDIR/body.md"; do
    RELEASE_BODY_FILE="$body" notes
    [ "$status" -eq 0 ] || fail "exited $status with body '$body': $output"
    argv="$(cat "$BATS_TEST_TMPDIR/argv.txt")"
    # An empty value contributes no flag at all, rather than `--locales ''`,
    # which the generator would read as "no locales".
    not_contains "$argv" "--locales" || fail "an empty STORE_NOTES_LOCALES became a flag: $argv"
    [ "$(cat "$BATS_TEST_TMPDIR/locales.txt")" = "" ] \
      || fail "an empty STORE_NOTES_LOCALES reached the generator as $(cat "$BATS_TEST_TMPDIR/locales.txt")"
  done
  contains "$(cat "$BATS_TEST_TMPDIR/argv.txt")" "--from-body" || fail "the body path did not run last"
}

@test "a release body file that is not there falls back to the commits" {
  fake_node
  RELEASE_BODY_FILE="$BATS_TEST_TMPDIR/absent.md" notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$BATS_TEST_TMPDIR/argv.txt")" "--from-commits" || fail "unexpected argv: $(cat "$BATS_TEST_TMPDIR/argv.txt")"
}

@test "a generator of the consumer's own is not run, and the run says to delete it" {
  mkdir -p "$ROOT/scripts/release"
  printf 'import { writeFileSync } from "node:fs";\nwriteFileSync("%s/ran", "");\n' "$BATS_TEST_TMPDIR" \
    > "$ROOT/scripts/release/notes.mjs"
  commit "fix: a fix"
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -e "$BATS_TEST_TMPDIR/ran" ] || fail "the consumer's notes.mjs was run"
  contains "$output" "::warning::scripts/release/notes.mjs is not run" || fail "no warning: $output"
  contains "$output" "store-notes.prompt.md" || fail "the warning does not say where the app's part goes: $output"
  [ "$(meta store-notes.txt)" = "$(printf 'Fixed\n• A fix.')" ] || fail "the package's generator did not run: $(meta store-notes.txt)"
}

# The addendum was release-notes.prompt.md before it took the name the store
# notes carry everywhere else. Under the old name the generator never reads it,
# and the only symptom would be an LLM draft without the app's own tone.
@test "a prompt addendum under its old name is not read, and the run says to rename it" {
  printf 'Old addendum.\n' > "$ROOT/release-notes.prompt.md"
  commit "fix: a fix"
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning::release-notes.prompt.md is not read: the prompt addendum is store-notes.prompt.md" \
    || fail "no warning: $output"
}

@test "an addendum under the new name is not warned about, even beside the old one" {
  printf 'Old addendum.\n' > "$ROOT/release-notes.prompt.md"
  printf 'New addendum.\n' > "$ROOT/store-notes.prompt.md"
  commit "fix: a fix"
  notes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$output" "::warning::" || fail "warned although store-notes.prompt.md is there: $output"
}

@test "a generator that fails fails the step" {
  commit "feat: a feature"
  STORE_NOTES_LLM_EFFORT=off notes
  [ "$status" -ne 0 ] || fail "exited 0 although the generator failed: $output"
  contains "$output" "STORE_NOTES_LLM_EFFORT: expected one of" || fail "the generator's reason is not in the log: $output"
}

# What the generator produced is asserted, not trusted: the lanes read both files.
@test "a generator that produces nothing is fatal" {
  fake_node nothing
  notes
  [ "$status" -ne 0 ] || fail "accepted a generator that produced nothing: $output"
  contains "$output" "produced no store-notes.json" || fail "unexpected message: $output"
}

@test "no node on PATH is an error naming it" {
  mkdir -p "$BATS_TEST_TMPDIR/bare"
  for tool in dirname mkdir; do ln -s "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bare/$tool"; done
  run env PATH="$BATS_TEST_TMPDIR/bare" "$BASH" "$REPO_ROOT/scripts/release/gen-store-notes.sh"
  [ "$status" -ne 0 ] || fail "exited 0 without node: $output"
  contains "$output" "missing command: node" || fail "unexpected message: $output"
}
