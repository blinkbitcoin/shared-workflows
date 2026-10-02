# 8. release-please owns versioning; store notes are generated prose

- **Status:** Accepted
- **Date:** 2026-09-05 (manifest mode and the merge rule ruled on 2026-09-06)

## Context

Version, changelog, tag, GitHub release and store notes drift apart when a
human maintains them. Apple rejects a build for an already-released version, so
internal builds must carry the version that will ship. And a changelog is not a
store note: a list of PR links is for developers, prose is for users.

## Decision

Conventional commits in, one release PR out; merging it is the only human step.

- `release-please-config.json` + `.release-please-manifest.json`, **manifest
  mode only** — an inline `release-type` makes the action ignore both files.
- The release PR **must be squash- or rebase-merged**: a merge commit hides the
  release subject, so `resolve-version.sh` also reads `HEAD^2` (the shared
  script; `make version` runs it from `@blinkbitcoin/app-tooling`).
  Order: HEAD tag → release commit → `RELEASE_PR_TITLE` → open PR → patch+1.
- Build number = first-parent commit count + `BUILD_NUMBER_OFFSET` (default
  1000): cross-platform, monotonic, idempotent; set in `app.config.ts`, no `sed`.
- `gen-store-notes` (the template's `scripts/release/notes.mjs` until
  shared-workflows v0.19.0 shipped it in `@blinkbitcoin/app-tooling`) —
  deterministic "New / Improved / Fixed" prose,
  truncated at word boundaries (4000 TestFlight, 500 Play), optionally
  rewritten by a validated LLM pass (`STORE_NOTES_LLM_PROVIDER` = `anthropic`
  or `openai`), falling back to it; `STORE_NOTES_INCLUDE_CHANGELOG` appends.
  *Refined 2026-09-22 by [0021](app-0021-store-notes-drafted-on-the-release-pr.md):
  the LLM pass moved from build time to the release PR, and the prompt to
  `store-notes.prompt.md`.*

## Consequences

Store notes attach once to the GitHub release, so the tracks cannot diverge and
editing `## Store notes` in its body overrides them. Commit hygiene is
load-bearing, squash-merge is a repository setting a fork has to keep, and
history on main must never be rewritten or build numbers move.

## Alternatives

- **changesets** — rejected: per-PR files; esign removed them too.
- **`github.run_number` as build number** — rejected: not commit-derivable.
- **Hand-written store notes** — rejected: they drift between tracks.
