# 13. CI on `main` and the internal release queue per commit; only store jobs share a queue

- **Status:** Accepted
- **Date:** 2026-09-19

## Context

GitHub keeps one *pending* run per concurrency group and evicts the older one.
Two groups were shared by every push to `main`: `ci-refs/heads/main`, and the
`release` queue that all store-affecting workflows joined so that two of them
never touch a store at once. An internal release run spends ~35 minutes in
Prepare waiting for its commit's CI before it builds. So a release PR merged
behind a fix — the normal sequence — had its own internal build cancelled with
zero jobs run, and the release's beta failed its green gate; `v0.2.3`,
`v0.2.4` and `v0.2.5` each needed a manual dispatch. The same rule cost the
middle commit of two quick merges its CI run on `main` (`5c6a1a1`, `1eb3037`),
after which its internal release refused to build.

## Decision

Nothing that runs on a push to `main` shares a queue with anything else.

- `.github/workflows/ci.yml` — group `ci-<ref>` on a branch (newest push
  cancels), `ci-refs/heads/main-<sha>` on `main`.
- `.github/workflows/cd-internal.yml` — group `release-internal-<sha>`.
  Its store-touching jobs — `upload-ios`, `upload-android`, `upload-huawei`,
  `ota-internal` — join the `release` queue individually, at job level. Since
  [0026](https://github.com/blinkbitcoin/react-native-mobile-template/blob/main/docs/decisions/0026-cd-pipelines-from-shared-workflows.md) those jobs are
  shared-workflows' `publish-internal.yml`, which sets the job-level group;
  the per-commit group stays here, because a reusable workflow cannot name one
  for its caller.
- `cd-beta.yml`, `cd-production.yml`, `cd-ota-hotfix.yml` — keep the
  shared `release` queue: they promote, and are dispatched by a person or by
  release-please, never in bursts.
- `scripts/release-workflows.test.mjs` — pins which group each caller carries;
  that exactly the store jobs join the queue is pinned upstream, in
  `test/pipelines.test.mjs`.

## Consequences

Two commits' CI and internal builds run side by side, so two pushes inside one
window cost two E2E stages and two native builds. A *pending* upload can still
be evicted by the next pending store job — two uploads queued within minutes
of each other — which shows as a red internal run that `gh run rerun --failed`
finishes; [0014](app-0014-green-gate-heals-itself.md) covers the beta side.

## Alternatives

- **Trigger the internal release from `workflow_run`** — the beta gate's
  discovery window would wait on a run that does not exist yet while holding
  the store queue: a deadlock.
- **Serialize every store job per platform** — more groups with the same
  eviction rule; not worth it while uploads take minutes.
