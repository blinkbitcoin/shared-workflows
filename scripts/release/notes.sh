#!/usr/bin/env bash
# Produce the store-notes bundle in $WORKFLOWS_RELEASE_META_DIR:
#
#   store-notes.json  {"<locale>": {"testflight","play","appstore"}}
#   notes-store.txt   the plain-text notes handed to the store lanes
#   notes.md          the human-readable release body
#
# The consumer owns the real generator (scripts/release/notes.mjs); this script
# only calls it and, when the consumer does not ship one, writes a usable
# fallback rather than failing the release: an empty store-notes.json plus the
# commit subjects as notes. A release whose notes are literally the commit log
# is a bad release note, not a broken pipeline - so it warns loudly.
#
# Env: NOTES_LOCALES (empty: the generator picks the locales), RELEASE_BODY_FILE (a release body, from the
# release-body-file input or fetched by release-body.sh; switches notes.mjs to
# --from-body --body-section).
# Usage: notes.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"

root="$(consumer_root)"
mkdir -p "$WORKFLOWS_RELEASE_META_DIR"
cd "$root"

# The locales are passed both ways on purpose: $NOTES_LOCALES is the older
# contract and a generator may still read it, but a CLI flag is what a
# hand-run of notes.mjs is debugged with, and it is what the template's
# generator takes. Built as an array so an empty value contributes no argument.
#
# Empty stays empty, in the flag and in the environment alike. The generator
# knows which listings the app has (the template's reads the locale
# directories under fastlane/metadata/ios); a default filled in here used to
# win over that, so an app with de-DE metadata got en-US-only notes from CI and
# both locales from the same command on a laptop.
locale_args=()
[ -z "${NOTES_LOCALES:-}" ] || locale_args=(--locales "$NOTES_LOCALES")

group "release notes"
if [ -f "scripts/release/notes.mjs" ]; then
  require_cmd node
  if [ -n "${RELEASE_BODY_FILE:-}" ] && [ -f "$RELEASE_BODY_FILE" ]; then
    # --body-section: the body is a whole changelog entry (headings, links,
    # commit references); the generator takes the section a store listing can
    # actually use rather than the raw markdown.
    log "running the consumer's notes.mjs --from-body --body-section"
    NOTES_LOCALES="${NOTES_LOCALES:-}" \
      node scripts/release/notes.mjs --from-body "$RELEASE_BODY_FILE" --body-section \
      "${locale_args[@]+"${locale_args[@]}"}" --out "$WORKFLOWS_RELEASE_META_DIR"
  else
    log "running the consumer's notes.mjs --from-commits"
    NOTES_LOCALES="${NOTES_LOCALES:-}" \
      node scripts/release/notes.mjs --from-commits \
      "${locale_args[@]+"${locale_args[@]}"}" --out "$WORKFLOWS_RELEASE_META_DIR"
  fi
else
  printf '::warning::consumer has no scripts/release/notes.mjs - falling back to commit subjects; store listings will get generic notes\n' >&2
  printf '{}\n' > "$WORKFLOWS_RELEASE_META_DIR/store-notes.json"
  last_tag="$(git tag --list 'v*' --sort=-v:refname 2>/dev/null | head -1 || true)"
  if [ -n "$last_tag" ]; then
    git log --no-merges --format='- %s' "$last_tag..HEAD" > "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" || true
  else
    git log --no-merges --format='- %s' -n 50 > "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" || true
  fi
  # An empty notes file makes App Store Connect reject the submission, so never
  # ship one: fall back to a single generic line.
  [ -s "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" ] ||
    printf -- '- Bug fixes and improvements\n' > "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt"
  {
    printf '## %s (%s)\n\n' "${APP_VERSION:-unreleased}" "${APP_BUILD_NUMBER:-0}"
    cat "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt"
  } > "$WORKFLOWS_RELEASE_META_DIR/notes.md"
fi

# notes.mjs is the consumer's, so assert the two files the store lanes need
# rather than trusting it produced them.
for f in store-notes.json notes-store.txt; do
  [ -f "$WORKFLOWS_RELEASE_META_DIR/$f" ] || die "release notes step produced no $f in $WORKFLOWS_RELEASE_META_DIR"
done
[ -f "$WORKFLOWS_RELEASE_META_DIR/notes.md" ] || cp "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt" "$WORKFLOWS_RELEASE_META_DIR/notes.md"

gh_env RELEASE_NOTES_STORE_FILE "$WORKFLOWS_RELEASE_META_DIR/notes-store.txt"
log "release-meta contents:"
ls -l "$WORKFLOWS_RELEASE_META_DIR" >&2
endgroup
