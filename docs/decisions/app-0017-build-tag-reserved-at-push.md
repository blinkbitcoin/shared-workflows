# 17. The build tag is reserved at push time, not when the release is published

- **Status:** Accepted
- **Date:** 2026-09-19

## Context

Every `Pre-release / Publish` between 01:30 and 03:10 UTC on 2026-09-19
failed with `HTTP 403: Resource not accessible by integration`, and so did
every self-heal dispatch ([0014](app-0014-green-gate-heals-itself.md)). Eight
throwaway runs isolated it: same token, same call, some commits refused,
others not, and `--target main` always fine. A `git push` of the same tag
gave the reason the releases API hides: GitHub treats a **new tag** as
introducing the workflow files of its commit, compared with the default
branch's tip, and refuses `GITHUB_TOKEN` when any `.github/workflows/*`
differs ("create or update workflow without `workflows` permission"). The
tag was created an hour after the push, and by then a later merge had
touched a workflow.

## Decision

Create the `vX.Y.Z-build.N` tag seconds after the push, while the commit is
still the tip, and publish the release on the existing tag later.

- `.github/workflows/cd-internal.yml` — `reserve-tag: true` and
  `contents: write` on the prepare job.
- shared-workflows `build-prepare.yml` (0.6.0) — `Resolve version` and
  `Reserve build tag` run before the green gate and before `Setup`; a red gate
  deletes the tag this run reserved. `scripts/release/reserve-tag.sh` is
  idempotent and explains the refusal when it still happens.
- shared-workflows `release-assets.sh` — `create-prerelease` passes no
  `--target` when the tag exists, so no ref is created at publish time.
- `scripts/release-workflows.test.mjs` — pins the flag and the permission.

## Consequences

A `-build.N` tag can exist for a few minutes before its release does, and
stays behind if a run dies in a way its cleanup step does not catch. The
window is not zero: a merge that lands in the seconds between the push and
Prepare's first steps, and touches a workflow, still refuses the tag; the
error says so and a re-run after main settles finishes it. A self-heal
dispatch at an *old* release tag still cannot reserve a tag if a workflow
changed since; that run fails loudly rather than silently, and the option of
attaching its assets to the release itself is noted in shared-workflows#29.

## Alternatives

- **A GitHub App or PAT with `workflows` permission** — the escape hatch the
  optional `RELEASE_TAGGER_*` secrets still offer; rejected as the default in
  [0011](app-0011-release-chain-by-dispatch.md).
- **Actions artifacts instead of pre-releases** — no tags at all, but a
  90-day retention and a different hand-off to beta; a larger redesign.
