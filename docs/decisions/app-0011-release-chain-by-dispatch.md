# 11. The release chain is plain `workflow_dispatch`, not a GitHub App

- **Status:** Accepted
- **Date:** 2026-09-18

## Context

Everything release-please creates — the release PR, the tag, the `vX.Y.Z`
release — is created with the workflow's own `GITHUB_TOKEN`, and GitHub never
starts a workflow from an event that token caused. So `cd-beta.yml` and
`ci-web.yml`, both triggered on `release: published`, never fired: `v0.2.2`
shipped and beta never ran. The documented remedy was a "release tagger"
GitHub App plus two secrets, so the release would be App-authored. That is an
App to register and rotate for one hop, and a `release:` trigger fed by an
App would also fire on every `-build.N` pre-release from `cd-internal`.

## Decision

The rule has two exemptions, `workflow_dispatch` and `repository_dispatch`, so
`cd-release.yml` starts the follow-on work itself, at the tag, with the
default token. No App, no secrets.

- `.github/workflows/cd-release.yml` — after `release_created`,
  `gh workflow run cd-beta.yml --ref $TAG -f tag=$TAG` and
  `gh workflow run ci-web.yml --ref $TAG -f deploy=true`; after `prs_created`,
  `gh workflow run ci.yml` on the release PR's branch, because a bot-authored
  PR's own `pull_request` runs wait for approval and turn red on merge. The
  job grants `actions: write`.
- `.github/workflows/cd-beta.yml`, `ci-web.yml` — `workflow_dispatch` only;
  the `release:` triggers are gone.
- `scripts/release-workflows.test.mjs` — pins the three dispatches, their
  gates, and that no `release:` trigger or App reference remains.

Since then the job itself moved to shared-workflows' `pr-release.yml`, which
runs the same three dispatches from its `dispatch-on-release` and
`ci-workflow` inputs; the decision is unchanged.

`--ref $TAG` on purpose: the dispatched run's `github.sha` is the release
commit, which is what `cd-beta-retry.yml` matches a failed beta run on.

## Consequences

The release PR carries a full CI run per update (E2E included) — free on a
public repository, one `if:` to drop on a private one. Its `pull_request`
entries still show as "awaiting approval" and are marked failed on merge;
the dispatched run is the one to read. A consumer that already has an App
keeps using `publish-github-release.yml`'s optional secrets in shared-workflows.

## Alternatives

- **The GitHub App** — more moving parts for the same result, and a
  `release:` listener that then needs a `prerelease` filter everywhere.
- **`workflow_run` chaining** — the beta gate's discovery window would wait
  on an internal run that does not exist yet while holding the store queue.
