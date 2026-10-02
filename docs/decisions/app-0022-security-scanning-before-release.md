# 22. Security scanning before release

- **Status:** Accepted. Where the scanners live: refined by [0025](app-0025-security-scanners-from-the-shared-tooling.md) (2026-09-30); they are shared-workflows' own now.
- **Date:** 2026-09-24

## Context

The family scans for some things already - `pnpm audit`, a licence allowlist,
CodeQL, gitleaks, zizmor - but nothing reads the dependency graph for known
vulnerabilities or malicious-package records, nothing pattern-matches app
source for mobile-specific mistakes, and the install-time supply-chain
settings are trusted rather than asserted. AI-driven supply-chain attacks were
the prompt for looking at this.

## Decision

Scanners write SARIF; a single verdict step applies the threshold. Place each
check by what it reads: source on every pull request, built binaries at the
production dispatch. Deterministic scanners can block; an LLM reviewer
annotates until a consumer explicitly gives it teeth, because a gate that
flakes gets disabled or teaches people to merge past red.

- `scripts/security/dependencies.sh`, `code.sh`, `policy.sh`, `sbom.sh`, `bundle.sh`,
  `mobile.sh`, `binaries.sh`, `review.sh`, `review-codebase.sh` - one scanner each,
  one SARIF each, never failing on their own finding. The two LLM jobs share
  one provider-portable adapter (`@blinkbitcoin/app-tooling/llm`, the template's
  `scripts/lib/llm/` until shared-workflows v0.19.0) with the store notes and
  are off until a repository configures a provider and a key.
- `scripts/security/verdict.mjs` - merges the SARIFs and applies the
  threshold; the only script allowed to fail a run.
- `scripts/security/local.sh` - runs every enabled scanner, then the verdict;
  `make check-security` runs it.

Tunables live in `security-settings.json`, one file in the repository, with an
environment variable able to override any of them. `make check-security*` is
what a laptop runs today and what a reusable workflow will call once it
lands, so the two are designed to give the same answer - CI does not call it
yet (Consequences).

Jev is excluded: a closed, waitlisted decision model whose own documentation
says adversarial input moves its verdicts, offering no detection an LLM
reviewer or gitleaks lacks.

## Consequences

A first run produces a baseline of findings; each gets a reasoned ignore in
its scanner's own config, never a threshold change. The baseline this record
started from (`uuid@7.0.3` failing the run) has since been accepted with a
reasoned ignore; the current one is in `docs/security.md`, "The current
baseline".
Scanners are external CLIs, so `make check-security` is minutes and stays out
of `make check` and `make ci`, like `check-code-scanning`; unlike `check-code-scanning` it
also has no CI caller yet at all, on any workflow - wiring it in is a later,
separate stage. A repository that finds the whole feature overkill sets
`SECURITY_ENABLED=false`.

## Alternatives

- **Fail every run on any finding** - rejected: a first run against a real
  lockfile and a real workflow set produces findings on day one, and a gate
  nobody can turn green gets disabled rather than fixed.
- **One combined scanner script instead of one per engine** - rejected: each
  scanner has its own installation, its own flags and its own failure mode: a
  single script would hide which one broke and make skipping just one harder
  than an environment variable.
