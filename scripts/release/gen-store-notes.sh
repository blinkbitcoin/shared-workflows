#!/usr/bin/env bash
# Produce the store-notes bundle in $WORKFLOWS_RELEASE_META_DIR:
#
#   store-notes.json  {"<locale>": {"testflight","play","appstore"}}
#   store-notes.txt   the plain-text notes handed to the store lanes
#   release-notes.md  the human-readable release body (a copy of store-notes.txt)
#
# The generator is @blinkbitcoin/app-tooling's gen-store-notes program, run from
# this checkout of shared-workflows (packages/app-tooling/bin/gen-store-notes.mjs)
# in the consumer's directory, so it reads the consumer's commits, its
# fastlane/metadata/ios locales and its optional store-notes.prompt.md. A
# consumer ships no generator of its own: one left at scripts/release/notes.mjs
# is not run, and the run says so (the Contract job's no-copy.gen-store-notes row
# blocks it too). The app's prompt addendum is store-notes.prompt.md;
# one still under its old name, release-notes.prompt.md, is not read, and the
# run says so too.
#
# Env: STORE_NOTES_LOCALES (empty: the generator picks the locales),
# WORKFLOWS_FASTLANE_DIRECTORY (the `fastlane-directory` input: where the
# metadata/ios the generator reads the locales from lives; fastlane when empty), RELEASE_BODY_FILE (a release body, from the
# release-body-file input or fetched by release-body.sh; switches the generator
# to --from-body --body-section).
# Usage: gen-store-notes.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"

# Absolute before the cd below, which would break a relative $0.
generator="$(cd "$(dirname "$0")/../../packages/app-tooling/bin" && pwd)/gen-store-notes.mjs"
root="$(consumer_root)"
mkdir -p "$WORKFLOWS_RELEASE_META_DIR"
cd "$root"

# The locales are passed both ways on purpose: $STORE_NOTES_LOCALES is the older
# contract, but a flag is what a hand-run of store-notes is debugged with.
# Built as an array so an empty value contributes no argument.
#
# Empty stays empty, in the flag and in the environment alike. The generator
# reads the locale directories under the app's fastlane/metadata/ios; a
# default filled in here used to win over that, so an app with de-DE metadata
# got en-US-only notes from CI and both locales from the same command on a
# laptop.
generator_args=()
[ -z "${STORE_NOTES_LOCALES:-}" ] || generator_args=(--locales "$STORE_NOTES_LOCALES")
generator_args+=(--fastlane-directory "${WORKFLOWS_FASTLANE_DIRECTORY:-fastlane}")

group "store notes"
require_cmd node
[ ! -f "scripts/release/notes.mjs" ] ||
  warn 'scripts/release/notes.mjs is not run: the store notes come from the gen-store-notes program in @blinkbitcoin/app-tooling. Delete it and its test, and keep what the app adds to the prompt in store-notes.prompt.md'
# The addendum's old name. Not read, so an app that kept it would lose its own
# product, audience and tone from every LLM draft without a word.
[ ! -f "release-notes.prompt.md" ] || [ -f "store-notes.prompt.md" ] ||
  warn 'release-notes.prompt.md is not read: the prompt addendum is store-notes.prompt.md. Rename it'
if [ -n "${RELEASE_BODY_FILE:-}" ] && [ -f "$RELEASE_BODY_FILE" ]; then
  # --body-section: the body is a whole changelog entry (headings, links,
  # commit references); the generator takes the section a store listing can
  # actually use rather than the raw markdown.
  log "running gen-store-notes --from-body --body-section"
  STORE_NOTES_LOCALES="${STORE_NOTES_LOCALES:-}" \
    node "$generator" --from-body "$RELEASE_BODY_FILE" --body-section \
    "${generator_args[@]}" --out "$WORKFLOWS_RELEASE_META_DIR"
else
  log "running gen-store-notes --from-commits"
  STORE_NOTES_LOCALES="${STORE_NOTES_LOCALES:-}" \
    node "$generator" --from-commits \
    "${generator_args[@]}" --out "$WORKFLOWS_RELEASE_META_DIR"
fi

# Assert the two files the store lanes need rather than trusting the
# generator produced them.
for f in store-notes.json store-notes.txt; do
  [ -f "$WORKFLOWS_RELEASE_META_DIR/$f" ] || die "store notes step produced no $f in $WORKFLOWS_RELEASE_META_DIR"
done
[ -f "$WORKFLOWS_RELEASE_META_DIR/release-notes.md" ] || cp "$WORKFLOWS_RELEASE_META_DIR/store-notes.txt" "$WORKFLOWS_RELEASE_META_DIR/release-notes.md"

gh_env STORE_NOTES_FILE "$WORKFLOWS_RELEASE_META_DIR/store-notes.txt"
log "build-info contents:"
ls -l "$WORKFLOWS_RELEASE_META_DIR" >&2
endgroup
