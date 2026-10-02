# 16. Workflow and job names say what a step is for, not which tool runs it

- **Status:** Accepted
- **Date:** 2026-09-19

## Context

A run graph reads "caller job / called job", by people who have not read the
runbook or a Fastfile. It said "Export / <the browser test tool>", "Fastlane
Lane / ios upload_internal", "GitHub Release / Release", "Stage Note",
"Baseline". A
thirty-year engineer asked what a lane is; nobody outside fastlane uses the
word.

## Decision

Names carry purpose, in the vocabulary of the stores and of the family.

- Callers (this repo): `Pre-release`, `Release`, `Attach store notes`,
  `Record stage`, `Attach stage note`, `Fingerprint baseline`, `Web`;
  `CD / Release` for the workflow that cuts the release and starts beta and
  web; job ids match names (`upload-ios`, `upload-android`).
- Called (shared-workflows 0.4.1): `Store / Store` for every store operation,
  `Publish` for the GitHub release, `Web / Build | E2E | Deploy`. A bats test
  there refuses any display name containing "lane".
- Kept: Internal, Beta, Production, Upload, Promote, Phased, Rollout, Halt —
  TestFlight's and Play's own words.

The order "Promote iOS / Store" is GitHub's: the caller's name is what
distinguishes jobs in a workflow's own graph, so it comes first.

## Consequences

`workflow_run` listeners match on display names, so a rename can silently
disconnect one; `scripts/release-workflows.test.mjs` checks every listener
against the real names (the beta retry was dead for two days that way).
Consumer-visible renames in shared-workflows are `fix`, not `docs`, or
release-please ships nothing.

## Alternatives

- **Name the called job after the lane** — fastlane vocabulary in every store
  job, repeated under a caller that already says the operation.
- **"Deploy to Pages"** — names today's target; the interface outlives it.
