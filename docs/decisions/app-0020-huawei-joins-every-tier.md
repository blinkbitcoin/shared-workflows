# 20. Huawei AppGallery on every tier, because a tier is a submit flag

- **Status:** Accepted
- **Date:** 2026-09-21

## Context

[0019](app-0019-huawei-appgallery-release-lane.md) rejected a beta Huawei job on the
grounds that no one had asked for a test track. Parity with Apple and Google was
then asked for: a Huawei submission on every push and on every release, not only
on the production dispatch. AppGallery makes that cheaper than it sounds. It has
**one version slot per app and no tracks**, so a tier is not a destination: the
same submission carries `use_testing_version` with manual review skipped (up to
100 testers, automated review, hours), or with review left on (up to 5,000
testers, 1 to 3 working days), or neither flag, which is the formal release.

## Decision

Run AppGallery on all three tiers, behind `HUAWEI_UPLOADS_ENABLED` as before.

- `fastlane/lanes/huawei.rb` — one `huawei_upload!` helper with three submit
  flavours; the lanes are `upload_huawei_internal`, `promote_huawei_beta` and
  the unchanged `upload_huawei`.
- `.github/workflows/cd-internal.yml` — `upload-huawei` after
  `upload-android`; `cd-beta.yml` — `huawei-binary` and `promote-huawei`
  after `github-release`. Every one of them stays outside every downstream
  `needs`, so a third-party review queue can never gate main or a release.
- Each tier **re-uploads**: AppGallery has no promote endpoint, and the beta
  tier's `build_info` on the bundle staged from the tag is what gives it the
  bytes-from-the-tag guarantee the Play and TestFlight promotions have.
- One slot means one submission at a time, so the lane reads the app record's
  `releaseState` and **skips with a message** rather than failing when a version
  is already in flight. The check is fail-open: unknown state means upload.

## Consequences

The plugin's testing fields are reverse-engineered from the console rather than
published, and they now sit on the every-push path; the plugin is pinned exactly
and the submit body is logged verbatim. Same-versionCode re-upload is unverified
— if AppGallery refuses it, the fallback is
`huawei_appgallery_connect_submit_for_review` guarded on the record's version
code. Testers stay console-only and have to be re-selected per release, hence
the `huawei-testers` checklist step.

## Alternatives

- **Submit-only on beta, reusing the internal upload** — rejected: the internal
  submission may have been skipped over a busy slot or superseded by later
  pushes, so beta could ship bytes that are not the tag's.
- **A slot or track per tier** — rejected: AppGallery has none to give.
- **Failing the job on a busy slot** — rejected: a review queue that is not ours
  must never turn main red. If `releaseState` turns out not to move during a
  testing review, the fix is widening the busy-state list, not this.
