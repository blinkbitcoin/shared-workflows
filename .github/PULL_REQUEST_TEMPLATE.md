<!--
The PR title becomes the commit message on main (squash merge) and feeds
release-please, which cuts the tag consumers pin. Conventional Commits, closed
scope enum — see CONTRIBUTING.md.
-->

## What and why

<!-- One paragraph. Link the issue: Closes #123 -->

## How to verify

<!-- The commands a reviewer runs. `make check` is the baseline. -->

## Checklist

- [ ] PR title is a Conventional Commit with a valid scope (`actions checks ci deps dev-config docs e2e lib native ota release self test tooling web workflows`)
- [ ] `make check` passes locally
- [ ] Every behaviour this PR adds or changes is tested here, error paths and branches included (bats in `test/`, `node:test` for `packages/dev-config`); the tests are named above
- [ ] `docs/consumer-guide.md` updated — a new or renamed input, output, secret or env var is a contract change
- [ ] Every doc and diagram that shows what changed is updated in this PR (searched each changed name with and without `.yml`; mermaid, ASCII and SVG diagrams read)
- [ ] Breaking for a consumer pinned at `@v0`? Say so here and mark the commit `!`
- [ ] Version pins moved in `scripts/lib/versions.sh`, not only in a workflow default (`make check-versions`)
- [ ] No secret, token or consumer-specific value hardcoded; nothing new reads `${{ secrets.* }}` outside a declared `secrets:` input
