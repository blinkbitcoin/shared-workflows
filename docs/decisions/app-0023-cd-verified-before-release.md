# 0023. Shared workflows pinned by SHA, and CD exercised on every PR

- **Status:** Accepted
- **Date:** 2026-09-26

## Context

Every CI and CD job runs a reusable workflow from `blinkbitcoin/shared-workflows`.
The callers used the moving `@v0` tag, which shared-workflows re-points the
moment one of its releases merges. A shared change therefore reached this
repository's CD with no PR here and no CI run against it. And no CI anywhere ran
the release half: shared-workflows tests its scripts with a stub `gh` and a
two-line fake generator, and the template's tests stopped at its own code. The
first run of the store-notes chain against this repository was the release PR
on main.

## Decision

Every call is pinned to one commit SHA with its version beside it, and a PR
runs the CD logic against the pinned shared code:

- `.github/workflows/*.yml` — every shared `uses:` is `@<sha> # vX.Y.Z`, all the same.
- `.github/dependabot.yml` — the `shared-workflows` group moves every pin in one PR, without the cooldown.
- `.github/zizmor.yml` — `hash-pin` for shared-workflows, `ref-pin` for the rest.
- `check-contract` (from `@blinkbitcoin/app-tooling` at the pin; `make check-contract`, CI's Checks / Contract) — every call
  against the inputs, their types, the secrets and the outputs its workflow declares, and one commit across every pin.
  Until shared-workflows v0.18.0 this was the template's own `scripts/workflow-contract.test.mjs`.
- The `store-notes` app suite of `@blinkbitcoin/app-tooling` (`make test-app`) — cd-release's
  `environment-variables`, the shared `build-env.sh`, `pr-store-notes.sh` and `gen-store-notes.sh`, and the
  `gen-store-notes` program with our prompt, end to end, then read back the way the release lanes read it. It was
  this repository's `scripts/release/store-notes.test.mjs` until the chain moved upstream.

## Consequences

A shared release changes nothing here until its Dependabot PR is green and
merged, and that PR's Unit job has run the new shared code against this
repository. The price is one PR per shared release. A fix no longer arrives by
itself: someone has to merge it. The PR CI still stands in for `gh`, the model
and release-please's body split; a dry-run of the whole workflow on GitHub is
the next step (the shared `pr-store-notes.yml` `dry-run` input).

## Alternatives

- **Keep `@v0` and trust shared-workflows' own CI** — it never checks out a consumer, so it cannot see a consumer's contract.
- **Pin to a version tag (`@v0.13.0`)** — readable, but a tag can be moved; a SHA cannot, and Dependabot keeps the comment.
