# Shared test suites that run against an app

- **Status:** Proposed
- **Date:** 2026-10-01

## Context

`check-contract` answers a static question about an app: are the files,
scripts, dependencies and workflow inputs the called workflows need present
and well formed? It cannot answer the behavioural one: given this app's files,
does the shared code do the right thing? The template answers that today with
tests in its own `scripts/`. They check the template's files against shared
code, and every app generated from the template inherits a copy:

| Template test | What of the app's it reads | What it proves |
| --- | --- | --- |
| `scripts/release/fingerprint.test.mjs` | `app.config.ts` and plugins, `fingerprint.config.js` | a version bump does not move the OTA runtime version |
| `scripts/release/store-notes.test.mjs` | `cd-release.yml`'s `environment-variables`, `store-notes.prompt.md` | the store-notes chain drafts, rewrites and reads back |
| `scripts/ci-e2e-ios.test.mjs`, `ci-suite-gates.test.mjs`,<br>`ci-web-gate.test.mjs` | the `if:` expressions in `ci.yml` and `ci-web.yml` | each suite runs or skips for each event and change |
| `scripts/release-workflows.test.mjs` | the `needs:` / `if:` graph of `cd-*.yml` | the release path runs as far as it can without store accounts |
| `scripts/gates.test.mjs` | the Makefile and package scripts | the gates `make ci` runs are the gates `check.yml` runs |
| `scripts/mise-environment.test.mjs` | `.mise.toml` `[env]` | what the shared machine setup relies on |

None of these tests' logic, fixtures or assertions belongs to the template.
The template only supplies the inputs. So:

- **The copies drift.** Nothing compares an app's copy with the template's or
  with the shared code they test. A copy that has been edited to pass stops
  guarding anything.
- **The shared code is tested where it isn't developed.** `store-notes.test.mjs`
  needs `WORKFLOWS_DIR` and skips without it. A fixture reworded upstream
  breaks the template, not shared-workflows.
- **Moving them one at a time is expensive.** Moving the fingerprint guard
  alone would take a program, a `check.yml` input and two contract entries,
  all to replace about 40 lines. Each later test would cost the same again.

The tests of shared code against fakes (the bats files, the `app-tooling`
unit tests) are out of scope. Running them inside an app re-tests the same
code against the same fakes.

## Decision

`@blinkbitcoin/app-tooling` ships **app suites**: `node:test` files that read
an app's files and run the shared code against them. One program runs them,
so the cost of the program, the CI gate and the contract entry is paid once.
After that, moving a test means copying it upstream, pointing it at the app
root and deleting it from the template.

### Names

The rule is to name a thing for what it checks and to use one name in every
interface:

| Interface | Name |
| --- | --- |
| program (`bin`) | `test-app` |
| make target in an app | `test-app` |
| package script in an app | `test:app` |
| `check.yml` input | `app-suites` |
| `app-tooling.json` section | `appSuites` |
| one suite | its subject: `fingerprint`, `store-notes`, `ci-gates`, `release-gates`, `make-gates`, `mise-environment` |

`test-`, not `check-`. It runs tests, the way `test-unit` and `test-scripts`
do, and the output is the test runner's.

### A suite

- **Location:** `packages/app-tooling/suites/<name>.suite.mjs`, shipped in the
  package's `files`. The `.suite.mjs` suffix is deliberate. `make test-package`
  runs every `packages/*/**/*.test.mjs`, and a suite there would run without
  an app.
- **Where it reads the app:** `APP_ROOT`, the absolute app root the runner
  sets. A suite reads nothing else from the environment. A suite that writes
  uses a `mkdtemp` copy, never `APP_ROOT` itself.
- **The app as data:** it reads the app through `readConsumer` and the reader
  helpers `check-contract` already exports (`readCallers`, `callerInputs`,
  `stackInput`, `readMakefile`, `readMiseTools`), so the two programs see the
  same app.
- **Its own frontmatter:** a `export const suite = { needs: [...], stacks: [...] }`
  that the runner reads before it runs anything.
  - `needs` lists paths relative to the app root.
  - `stacks` is `expo`, `bare` or both.
- **Helpers:** what the template's copies each re-implemented moves into
  `packages/app-tooling/lib/`, with sibling tests under the 100% gate:
  - the GitHub expression evaluator and the job-graph simulator (`ci-gates`
    and `release-gates`);
  - the `$GITHUB_ENV` parser;
  - the `gh` shim;
  - the OpenAI-compatible stub model (`store-notes`).

### The runner

```sh
test-app [--root DIR] [--suite NAME ...] [--list]
```

1. Read `app-tooling.json`'s `appSuites` section through `lib/config.mjs`.
   An unknown key is an error, the same as for every other section.
2. Work out the stack the way `check-contract` does.
3. For each suite, decide **run** or **skip, with the reason**.
   - It is skipped when its `stacks` leaves this stack out, when a file in
     `needs` is missing, or when `appSuites.skip` names it.
   - `--suite` narrows the list. Naming an unknown suite is an error.
4. Print one line per suite (`run fingerprint` /
   `skip store-notes: no .github/workflows/cd-release.yml`).
5. Run `node --test` over the suites that run, with `APP_ROOT` set and the
   output passed through, and exit with node's status. If nothing runs, it
   passes and says so.

`--list` prints step 4 and stops. It is how a reader sees what CI will run.

The runner is a bin like any other: `main(argv, io)` returning the exit code,
tested in-process, with one subprocess run for the guard.

### Choosing suites

- **Defaults:** every suite whose `stacks` includes the app's stack and whose
  `needs` are present. An app gets a new suite by taking the release that
  ships it.
- **Turning one off:** `"appSuites": { "skip": { "store-notes": "notes are written by hand" } }`.
  The reason is required and printed on every run, the same as
  `docs.allowTargetNames`.
- **A skip is never silent.** A missing file prints its reason. An app that
  wants a missing file to be a failure leaves the suite on, and
  `check-contract` already reports that file as required.

### Testing the suites themselves

A suite is a test, so the 100% coverage gate doesn't apply to it. What does
apply is that it has to be able to fail:

- **Fixture apps** live in `packages/app-tooling/fixtures/apps/<suite>/`.
  There is a `good/` app in the template's shape, and a `broken-<what>/` app
  for each assertion. For example `fingerprint/broken-version-in-extra/` puts
  `APP_VERSION` into `extra`.
- **`packages/app-tooling/suites.test.mjs`** runs every suite against its
  `good/` app and expects a pass. It runs it against each `broken-*/` app and
  expects a failure that names the broken thing. A suite whose broken fixtures
  pass is reported as unable to fail.
- **A drift check** (`test-app --list` over the template fixture) fails when a
  suite has no `good/` fixture or no broken one.

### In an app's CI

- **`check.yml` input:** `app-suites`, `boolean`, `default: false`. It is
  flipped to `true` in the release after the template and the terminal app run
  it green. A step runs the app's `test:app` script through `run-script.sh`,
  the same way `Licenses` does.
- **Contract entries:**
  - `package-script.test-app`, toggled by `check.yml:app-suites`;
  - one `no-copy.<suite>` for each template test a suite replaces, so an app
    that adopts the suite is told to delete its copy.
- **Versioning:** the suites move with the pin, the same as the workflows.
  The Dependabot PR that moves the pin runs the new suites against the app
  before it merges, which is what the template's ADR 0023 asks of every
  shared change. A release that makes a suite stricter lists it in its
  CHANGELOG under **May fail your build**.

### Order of migration

Each step is one shared-workflows PR, then one template PR at its release:

1. **The runner and `fingerprint`.** The suite checks iOS and Android, where
   the template's copy checks iOS only. In the same template PR,
   `fingerprint.config.js` becomes `createFingerprintConfig()` and
   `.fingerprintignore` is deleted.
2. **`store-notes`.** The pending plan for a shared chain test becomes this
   suite. The `environment-variables` JSON check becomes a `check-contract`
   rule, because it is static.
3. **`ci-gates` and `release-gates`**, with the expression evaluator and job
   graph in `lib/`.
4. **`make-gates`.**
5. **`mise-environment`.**

`check-unused-web` stays in the template. It tests the template's own knip and
Playwright configuration, not shared code.

## Consequences

- An app made from the template no longer carries about 1,800 lines of tests
  of shared behaviour (the eight files in the table). It gets them back, kept
  current, from the pin.
- **shared-workflows** now tests its release and CI logic against
  realistic apps in its own CI. Until now that only happened in the
  template's CI after a pin bump.
- **The cost:**
  - a new kind of thing in `app-tooling`: suites, the runner and fixture apps;
  - each suite needs fixtures that can fail, which is more upstream work than
    a test that only has to pass;
  - a new release that tightens a suite can fail an app's Dependabot PR. That
    is intended, and it is announced in the CHANGELOG.

## Open questions

1. **Laptops or CI only?** Should `make test` in an app run `test-app`? The
   suites take seconds, apart from `fingerprint`: four hashes, a few seconds.
   `store-notes` starts a local HTTP server on a random port. The proposal is
   yes, through `make ci` but not `make test`, so a laptop gets them before
   a push without slowing the inner loop.
2. **`release-gates`: a suite or contract rules?** Some of
   `release-workflows.test.mjs` is static: "the release job doesn't need the
   upload jobs" could be a `check-contract` rule over the callers. Some of it
   needs the job-graph simulation. The proposal is to split it at migration
   step 3, with each assertion going to whichever side can express it.
3. **Bare-stack apps:** `fingerprint` is Expo-only. Which suites a bare app
   gets is decided per suite through `stacks`, with no bare app to try them on
   yet.
