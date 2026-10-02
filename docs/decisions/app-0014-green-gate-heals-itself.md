# 14. The beta gate dispatches the internal build it is missing

- **Status:** Accepted
- **Date:** 2026-09-19

## Context

Beta refuses to promote a build whose internal release run is not green for
the same commit — the right rule, and it held. But when that run was lost
([0013](app-0013-per-commit-queues.md)) the gate could only fail and wait for a
human to dispatch the build by hand. Three releases in a row needed that.
Manual healing is not a pipeline, and a developer merging a release PR should
not have to know whether some other run is still going.

## Decision

The gate heals itself. When the internal run for the release commit is
missing, cancelled or failed, it dispatches `cd-internal.yml` at the
release tag once and waits for the run that dispatch creates.

- `.github/workflows/cd-beta.yml` — `require-green-dispatch: true` beside
  `require-green-workflow`, and `actions: write` on the prepare job.
- shared-workflows `scripts/release/require-green-run.sh` (0.5.0) — the
  dispatch, once; the replaced run is ignored; a dispatched run that also
  fails is fatal; `skipped` is never dispatched.
- `.github/workflows/cd-beta-retry.yml` — the second line: re-runs a failed
  beta when an internal run for `main` completes.
- `scripts/release-workflows.test.mjs` — pins the flag, the tag and the
  permission together.

## Consequences

There is no moment at which merging the release PR is too early. A beta may
now take an extra build's worth of time instead of failing fast. The prepare
job holds `actions: write`, which can also re-run and cancel workflows in this
repository. A genuine outage — a store or GitHub API refusing — still fails
and stays red, as it must; a rerun finishes the release once it is fixed.

## Alternatives

- **Re-run the cancelled internal run from the retry workflow** — the retry
  only sees completed internal runs; an evicted one never completed.
- **Document "wait for the previous build"** — the brittle instruction this
  replaces.
