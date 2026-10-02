# 18. Additive store-listing-sync lanes, gated and version-free

- **Status:** Accepted
- **Date:** 2026-09-19

## Context

The public store page was reachable only inside a tagged production release:
`release_production` writes `fastlane/metadata/**` while submitting a version.
A copy fix had to wait for a release, or be typed by hand into App Store
Connect and Play Console with no diff and no review trail. ADR 0008 and 0013
depend on `release_production` staying the one lane that touches a version, so
any fix here had to leave that guarantee alone.

## Decision

Add `sync_metadata` / `pull_metadata` lanes on both platforms, separate from a
version release, gated behind a repository variable so a fresh checkout cannot
write to a real store by accident.

- `fastlane/lanes/shared.rb` — `assert_metadata_sync_enabled!` requires
  `STORE_METADATA_SYNC_ENABLED=true`; `with_baseline_metadata` excludes
  per-version paths (`release_notes.txt`, `changelogs/`) from the staged push.
- `fastlane/lanes/ios.rb`, `android.rb` — `sync_metadata` pushes the staged
  tree with no binary, version bump or review submission; `pull_metadata`
  downloads the console's copy for review. Only iOS `sync_metadata` also
  pushes `fastlane/screenshots/<locale>/**`.
- `.github/workflows/cd-store-listing.yml` — the **CD / Store listing** workflow,
  dispatched independently of `cd-production.yml`, sharing its `release`
  concurrency group. `release_production` itself is unchanged.

## Consequences

The listing now has two writers, the tree and the console, so the tree must
stay the source of truth or they drift. A pull overwrites local prose with the
console's copy; the diff is the review step. Apple's constraint that the name,
subtitle, keywords, privacy URL and screenshots need a version in preparation
is now documented lane behaviour (`IOS_METADATA_EDIT_LIVE`), not a surprise
hit by hand in App Store Connect; the age rating is app-level and pushes in
both modes. Categories stay console-only: the template ships no
`primary_category.txt`, because `release_production` reads the same
`metadata_path` and a category found there also makes `deliver` rewrite the
four sub-category slots. A consumer opts in by creating the files.

## Alternatives

- **Flag-gate `release_production`** — rejected: regresses the
  version-submission isolation ADR 0008 relies on.
- **Bot PR from a CI pull** — rejected: needs `contents: write` on a job that
  already holds store credentials.
- **Console-only edits, no lane** — rejected: no diff, no review trail.
