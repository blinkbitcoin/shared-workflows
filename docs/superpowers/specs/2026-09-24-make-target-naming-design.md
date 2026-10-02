# Make target naming alignment

Date: 2026-09-24
Status: approved, not yet implemented

## Problem

Workflow files are grouped by filename prefix, because GitHub ignores
subfolders of `.github/workflows`: shared-workflows uses
`check-`/`build-`/`publish-`/`pr-`/`self-`, and this repo uses `ci-`/`cd-`,
matching its display names. The Makefile never got the same treatment. It
carries seven `check-*` targets alongside `typecheck`, `lint`, `knip`,
`spell`, `unit`, `coverage`, `codeql`, `e2e-ios` and one target whose words
are simply in the wrong order, `bundle-secrets-check`.

A reader cannot answer "what are all the static gates?" or "what are all the
test entry points?" from `make help`, and a red CI job does not name the
command that reproduces it. Grouping by prefix fixes both: the families sort
together in `make help`, and each CI job can carry the name of the target
that runs it locally.

## Constraint: pnpm script names are a cross-repo contract

shared-workflows calls the consumer's `pnpm` scripts **by name**:

| Script | Called from |
| --- | --- |
| `check:docs` | `check-code.yml`, `SCRIPT_NAME` |
| `check:release` | `check-code.yml`, `SCRIPT_NAME` |
| `check:ci` | `check-code.yml`, `run-consumer-or.sh` |
| `check:secrets` | `check-code.yml`, `run-consumer-or.sh` |
| `test:scripts` | `check-unit.yml`, input default |
| `build:web` | `build-web.yml`, input default |

These six are the names shared's `docs/adopting-an-existing-repo.md`
documents as the seam any consumer implements. They are not the whole
surface: `scripts/gates.test.mjs` asserts that **eighteen** script names CI
calls exist in `package.json`, adding `typecheck`, `lint`, `format:check`,
`spell`, `i18n:check`, `codegen:check`, `deps:check`, `deps:audit`,
`deps:licenses`, `check-prebuild`, `check:bundle-secrets`, `test` and
`test:coverage`.

**No `pnpm` script name changes.** Renaming any of them would break a
consumer or a gate for a cosmetic gain, and the eighteen are the reason to
leave the whole set alone rather than only the documented six. Where such a
script shells out to a make target, the target is renamed underneath it and
the script body follows; the script's own name stays.

## Design

Every target joins a prefix family. The families are: `check-` (static
gates), `test-` (anything that runs tests), `build-` (produces an artifact),
`dev-` (runs the app locally), `gen-` (writes generated files), `fix-`
(rewrites source in place), `verify-` (inspects a built artifact).

### Renames

| Now | Becomes | Family |
| --- | --- | --- |
| `typecheck` | `check-types` | check |
| `lint` | `check-lint` | check |
| `format-check` | `check-format` | check |
| `knip` | `check-knip` | check |
| `spell` | `check-spell` | check |
| `codeql` | `check-codeql` | check |
| `bundle-secrets-check` | `check-security-bundle` | check |
| `unit` | `test-unit` | test |
| `coverage` | `test-coverage` | test |
| `e2e-ios` | `test-e2e-ios` | test |
| `e2e-android` | `test-e2e-android` | test |
| `e2e-web` | `test-e2e-web` | test |
| `start` | `dev` | dev |
| `ios` | `dev-ios` | dev |
| `android` | `dev-android` | dev |
| `web` | `dev-web` | dev |
| `mock-api` | `dev-api` | dev |
| `i18n` | `gen-i18n` | gen |
| `codegen` | `gen-graphql` | gen |
| `badges` | `gen-badges` | gen |
| `format` | `fix-format` | fix |

### Unchanged

`check`, `check-code`, `check-gen`, `check-deps`, `check-ci`, `check-docs`,
`check-release`, `check-skills`, `check-secrets`, `check-prebuild`,
`check-slow`, `test-scripts`, `build-web`, `verify-ios`, `verify-android`,
`ci`, `test`, `init`, `doctor`, `install`, `clean`, `reset`, `help`, `ports`,
`version`, `release-notes`, `prebuild`.

### Additions

- `fix-lint`, wrapping the `lint:fix` script that exists in `package.json`
  but has no make target today.

### Deliberate exceptions

- **`prebuild` and `check-prebuild` keep their names.** `expo prebuild` is
  the tool's own term. A target named `build-native` would be harder to map
  to the command it runs, which is the opposite of the goal.
- **`test` stays an aggregate** (`test-unit` + `check-code`), matching
  `check` and `ci`. It is a family name and an entry point at once, which is
  true of `check` too.
- **No backwards-compatible aliases.** An app generated from this template
  owns its copy of the Makefile, so nothing an existing app runs breaks when
  this lands; aliases would double the surface `make help` has to explain and
  the AGENTS.md table has to carry.

## Files that change

- `Makefile`: target names, the `check`, `check-slow`, `ci` and `test`
  aggregates, and the `##` help text on each renamed line.
- `package.json`: the bodies of scripts that shell to make. No script name
  changes.
- `scripts/init.test.mjs` and `scripts/init.manifest.json`: the `--no-web`
  path pins target names in a `makeTargets` array, a `removeMakeTargets`
  fixture and a `docScrub` alternation regex. A grep for `make <name>` misses
  all three, so they are checked by hand.
- `jest.config.ts`: names a target in a comment.
- `AGENTS.md`: the command table. `scripts/check-docs.sh` asserts the table
  and the Makefile agree in both directions — a missing row fails, and a row
  naming a target that does not exist fails — so this file cannot drift.
- `docs/quality.md`, `docs/local-dev.md`, `docs/testing.md`, `docs/ci.md`,
  `README.md`, `CONTRIBUTING.md`, `mocks/README.md`, `docs/architecture.md`,
  `docs/template-usage.md`, `docs/native-extensions.md`,
  `docs/ota-and-crash-reporting.md`, and the ADRs under `docs/decisions/`
  that name commands in prose.
- `lefthook.yml`, `scripts/check-i18n.sh`, `scripts/check-coverage-empty.mjs`,
  `scripts/codeql-findings.mjs`, `scripts/ports.mjs`, `scripts/ports.test.mjs`,
  `scripts/init.manifest.json`, and the `.claude/skills/**` that invoke make.
- **Not** `docs/superpowers/**`: dated session records, excluded from the doc
  checks, left as written.

shared-workflows needs no change: no documented consumer script name moves.

## Verification

1. `make help` lists targets in prefix families with no orphans.
2. `make check-docs` passes, which is the AGENTS.md ↔ Makefile assertion.
3. `rg -n 'make (typecheck|lint|format|knip|spell|unit|coverage|codeql|e2e-|start|ios|android|web|mock-api|i18n|codegen|badges|bundle-secrets-check)\b'`
   returns hits only under `docs/superpowers/` and `CHANGELOG.md`.
4. `make check && make unit && make test-scripts` under their new names, then
   the full `make ci`.
5. CI green on the pull request, including the `Checks` job that runs the
   consumer's six contract scripts.

## Out of scope

The `check-security*` targets are defined by the security scanning design
(`2026-09-24-security-scanning-design.md`) and land with that work. This
change only renames what exists today, so the security spec can reference
final names.

## Commit

One commit, `fix(tooling)`: consumer-visible rename, so `fix` rather than
`docs` — a template consumer reading the release notes needs to see it.
