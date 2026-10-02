# 0024. Shared tooling as a git dependency at the workflows pin

- **Status:** Accepted
- **Date:** 2026-09-27

## Context

shared-workflows ships `@blinkbitcoin/app-tooling`: the consumer contract, its
checker and the pinned tool table. CI ran the checker from its own checkout of
the pinned commit, but a laptop had none, so the template kept copies of shared
code and compared them in CI. The package is published to GitHub Packages,
whose npm registry needs a token to install even a public package: every
install of a public template, on every laptop and CI job, would need one.

## Decision

Install the package from shared-workflows itself, at the commit the workflows
pin, so one commit covers both and no registry or token is involved:

- `package.json` — `github:blinkbitcoin/shared-workflows#<pin>&path:/packages/app-tooling`.
- `check-lockfile` (from the package, run by `pnpm check:audit`) — allows that one git source, at that commit, and nothing else.
- `fix-tooling-pin` (from the package, `make fix-tooling-pin`) — repoints every package of the family at the pin and relocks.
- `check-contract`'s `pin.one-commit` row (`make check-contract`, CI's Checks / Contract) — fails while the package and the pin disagree.

These three were the template's own `scripts/check-lockfile.sh`, `scripts/tooling-pin.mjs` and
`scripts/workflow-contract.test.mjs` until shared-workflows v0.18.0 shipped them.
- `.github/dependabot.yml` — npm updates leave the package alone.
- `Makefile` — `make check-contract` runs the checker from the package.

## Consequences

A laptop runs the checker CI runs, and later shared modules can be imported
instead of copied. The lockfile gate trusts one git source, but only the commit
CI already executes with this repository's token. Dependabot cannot move a git
dependency with the pins, so its pin-bump PR stays red until someone runs
`make fix-tooling-pin` on it: one manual step per shared-workflows release.

## Alternatives

- **GitHub Packages** — a token for every install of a public template.
- **npmjs.com** — a second release axis to keep equal to the pin, and an npm organisation to run.
- **Keep copies** — two copies of every shared file, compared in CI but never on a laptop.
