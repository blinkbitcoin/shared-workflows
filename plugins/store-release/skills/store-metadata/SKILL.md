---
name: store-metadata
description: Use when filling or checking the store listing an app ships in fastlane/metadata (the fastlane directory is FASTLANE_DIRECTORY, default fastlane) - description, keywords, URLs, categories, age rating, review contact, screenshots, icon and feature graphic - or when pushing that listing to App Store Connect and Google Play with the sync_metadata lane, or seeding it from the consoles with pull_metadata.
allowed-tools: Bash(bundle exec fastlane:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/scaffold.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/check-metadata.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/place-images.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/age-rating.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/sync.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/tests/run.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh:*)
---

# Store Metadata

## Overview

This skill covers the `meta-*` ids in the `store-setup` checklist:
`meta-scaffold`, `meta-ios-copy`, `meta-android-copy`, `meta-images`,
`meta-age-rating`, `meta-review-info`, and `meta-sync` — filling in,
validating, and pushing the public store listing.

**Core principle:** `fastlane/metadata/**` and `fastlane/screenshots/` are
the source of truth. Nothing reaches App Store Connect or Google Play
without `check-metadata.sh` passing first — `sync.sh` runs it itself and
refuses to call the lane if it fails.

The Huawei AppGallery listing is **console-only and outside this skill** —
nothing under `fastlane/metadata/**` reaches AppGallery, and the
`huawei-listing` step in `store-consoles` is where those fields are filled in
by hand.

### What sync owns, what CD owns per version, what stays console-only

The app's release runbook (in the React Native template,
`docs/release-runbook.md` "Store listing metadata") has the full table.
In short:

| CD owns per version | sync owns | Console-only |
| --- | --- | --- |
| Release notes, the binary, the review submission, track and rollout | Name, subtitle, description, keywords, promotional text, URLs, copyright, age rating, review contact, iOS screenshots, Play icon/feature graphic/screenshots | Apple: categories (until the category files exist), App Privacy labels, pricing, agreements, TestFlight groups. Play: content rating, data safety, target audience, tracks and testers |

## Procedure

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/scaffold.sh --locale en-US --platform both
# fill in the files by hand, or:
${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/scaffold.sh --from-console

${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/place-images.sh --platform ios screenshot1.png screenshot2.png
${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/place-images.sh --platform android icon.png featureGraphic.png phone1.png

${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/age-rating.sh --from-answers answers.txt

# App Review contact stays in the environment (APP_REVIEW_*), never in the
# repo - the review_information/*.txt files stay empty on disk.

${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/check-metadata.sh --platform both

${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/sync.sh both --dry-run
STORE_METADATA_SYNC_ENABLED=true ${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/scripts/sync.sh both --yes
```

## Four Facts From The Runbook You Must Not Miss

1. **A blank field cannot be pushed from the tree.** The staged copy drops
   zero-byte `.txt` files before either lane runs — `supply`/`deliver` treat
   presence as an instruction to overwrite. `fastlane/metadata/android/en-US/video.txt`
   is the case people hit: a removed Play promo video can only be cleared in
   the console.
2. **`overwrite_screenshots` replaces every display type per locale.** A
   locale directory holding only iPhone shots erases that locale's existing
   iPad set on the next push. Stage complete sets before pushing.
3. **Live mode needs no version in preparation and edits a small subset.**
   `IOS_METADATA_EDIT_LIVE=true` (or `live:true`) edits description,
   promotional text, the support/marketing URLs and copyright on the live
   version; name, subtitle, keywords, the privacy URL and screenshots need a
   version in "Prepare for Submission" and never push in live mode.

4. **`release_notes.txt` must be non-empty for the gate even though sync
   never pushes it.** CD writes the release notes per version, so the file's
   content on disk is never what ships — but `check-metadata.sh` still
   requires it to be filled, because an empty one is the shape a
   half-scaffolded tree has; do not relax the gate to work around it.

## After Editing the Scripts

Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/store-metadata/tests/run.sh` before committing
(`APP_REPO_ROOT=<an app checkout>` also compares the lists with that app's lanes
and the fastlane gem it vendors). The category id list and iOS screenshot size list
(`check-metadata.sh`, `place-images.sh`) and the age-rating key list
(`age-rating.sh`) are asserted against the vendored spaceship/deliver gem
files by the test suite — if fastlane is upgraded and those gem files
change shape, the tests will fail and the embedded lists need updating to
match.

`check-metadata.sh`'s length limits count Unicode code points, with exactly
one trailing newline stripped (so a field saved by an editor, which appends
a final newline, does not read as one character over) — never raw bytes,
which would over-count anything outside ASCII.

Android images (icon, feature graphic, screenshots) always live under
`fastlane/metadata/android/<locale>/images/`, never in a top-level
`fastlane/metadata/android/images/` — `supply` enumerates every directory
directly under `metadata/android` as a locale, so a global `images/` both
hides real images from it and gets pushed as a bogus locale.

## Common Mistakes

| Mistake | Consequence |
|---|---|
| Writing App Review contact details into `fastlane/metadata/ios/review_information/*.txt` instead of the `APP_REVIEW_*` environment | Those files must stay empty; `review_information` is filled from the environment by the lane itself, and a filled-in file is a committed reviewer credential |
| Adding `primary_category.txt` without the four sub-category files | `deliver` clears any of the four that is absent, so ship all four (they may be empty) or none |
| Leaving the template's `Replace this text` placeholder in any `.txt` file under `fastlane/metadata` | `check-metadata.sh` and the lane's own `assert_metadata_ready!` (the same `METADATA_PLACEHOLDER` literal from `fastlane/lanes/shared.rb`) both refuse it |
| Running `sync.sh` for real without `--dry-run` first | The dry run is the only free rehearsal of a push that overwrites a live listing |

## Red Flags — Stop

- **`check-metadata.sh` fails on one file and you are about to push
  anyway.** Stop. `sync.sh` refuses on its own, and don't route around it by
  calling the `bundle exec fastlane <platform> sync_metadata` lane directly
  — that lane refuses on its own too, when `STORE_METADATA_SYNC_ENABLED` is
  off or the `Replace this text` placeholder is present, so bypassing the
  script does not bypass the gate; and a first Play upload carrying
  placeholder text fixes the package name forever while the listing is
  wrong.
