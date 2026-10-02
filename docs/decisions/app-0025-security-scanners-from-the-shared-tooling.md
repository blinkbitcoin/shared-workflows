# 0025. Security scanners from the shared tooling

- **Status:** Accepted
- **Date:** 2026-09-30

## Context

0022 put every security scanner, the settings resolver and the verdict in this
repository under `scripts/security/`, about 2,100 lines plus 3,200 of tests.
shared-workflows' `check-security.yml` called those files by path, and its
contract made each one a required file. Every app adopting the workflows would
have had to copy them, and nothing would have held the copies together.

## Decision

The scanners are shared-workflows' own:

- The runners are in its `scripts/security/`. The modules they call are in
  `@blinkbitcoin/app-tooling`'s `lib/security-*.mjs`. The package ships copies
  of the runners, so `pnpm exec check-security [job]` runs what CI runs.
- This repository keeps only its settings and the files they name:
  - `security-settings.json`, with `jobs.code.rules` naming `rules/`;
  - `rules/`;
  - `.mobsf`.
- The Makefile's `check-security*` targets call the package's program. Their
  names are unchanged.
- The contract's `no-copy.security` row fails if `scripts/security/` comes back.

## Consequences

`scripts/` loses its biggest directory. A scanner fix lands once, for every
app, at the next pin bump. Scanner behaviour is now tested in shared-workflows
(bats per runner, node:test at 100% per module), not here. The Semgrep rule
tests (`semgrep --test rules/`) stay in `make check-security-code`, because
the rules are this repository's.

## Alternatives

- **Keep the copies, compared in CI:** the drift 0024 removed for the checker.
- **A per-runner override:** the same copies again; a new scanner goes upstream.
