# 19. Huawei AppGallery: a binary-only release lane behind its own toggle

- **Status:** Accepted
- **Date:** 2026-09-20

## Context

Huawei AppGallery was a loud stub: `upload_huawei` in `fastlane/lanes/future.rb`
raised, `docs/store-accounts.md` said "Not implemented", the runbook listed the
store under Future stores. Shipping there is two pieces of work of very
different size. Uploading a signed `.aab` and submitting it is the small one.
Making that bundle work on a device without Google Play Services — a Huawei
Mobile Services equivalent, or a fallback, for every runtime dependency on it —
is the large one, and belongs to the app rather than the release pipeline. Only
the small one is in scope here.

## Decision

Add a binary-only `upload_huawei` lane and run it on the release tier, behind a
toggle of its own.

- `fastlane/Pluginfile` — `fastlane-plugin-huawei_appgallery_connect` pinned to
  an exact version. Huawei publishes no first-party command-line tool.
- `fastlane/lanes/huawei.rb` — a `platform :android` lane, because
  shared-workflows runs `fastlane <platform> <lane>` and accepts only `ios` or
  `android`, so a top-level lane is unreachable from CI.
- `assert_huawei_uploads_enabled!` requires `HUAWEI_UPLOADS_ENABLED=true` on top
  of `STORE_UPLOADS_ENABLED`: a repository shipping only to Apple and Google
  must not acquire a third submission by setting the shared toggle.
- `.github/workflows/cd-production.yml` — `huawei-binary` and
  `huawei-release`, on `action=release` only and deliberately outside
  `github-release`'s `needs`, so a slow third-party store cannot hold up marking
  the release latest, the update publish or the web deploy.
- No metadata tree: AppGallery's listing fields stay console-only, so there is
  no `sync_metadata` counterpart and no `fastlane/metadata/huawei/**`.
- The lane pre-flights the credentials with an app-info call, because the
  plugin's token helper returns nil or false on an authentication error and its
  upload action treats that as a no-op — a wrong secret would otherwise be a
  green job that uploaded nothing.

## Consequences

This is the first `Pluginfile` entry, so `bundle install` becomes load-bearing:
without the gem the option-replay test fails with "no such fastlane action", and
`fastlane/test/validate_options.rb` has to load plugins explicitly because the
core loader does not. `huawei-binary` exists because Huawei's production
dispatch is its first upload rather than the promotion of a binary it already
holds, and the `.aab` lives on the release tag as an asset, not in the run — it
fails loudly when the tag carries none, which means the beta promote never ran.
There is no idempotency query, so a re-run re-uploads and relies on Huawei
rejecting a duplicate version code. And the pre-flight only covers the
credentials: the plugin submits only when its own upload reported success, so an
upload that fails mid-flight is still a green lane. Accepted for now; the
follow-up is a post-upload app-info assertion that the release state moved.

## Alternatives

- **A `platforms: huawei` dispatch choice** — rejected: the `platforms` input
  narrows by platform, and Huawei ships the Android bundle. `android` covers it,
  and the toggle is the real switch.
- **The beta tier as well** — rejected: no one has asked for a Huawei test
  track, and each extra tier is another job and another review queue to watch.
  Revisited by [0020](app-0020-huawei-joins-every-tier.md) (2026-09-21): parity was
  asked for, and AppGallery's single version slot makes a tier a submit flag.
- **A hand-written AppGallery Publishing API client in Ruby** — rejected: more
  code to own and keep current than a pinned community plugin, for the same two
  calls. It stays the fallback if the plugin is abandoned.
- **`submit_for_review: false` plus a separate submit lane** — rejected for now:
  it doubles the dispatch surface. It is the move if the submit stays flaky
  after `HUAWEI_SUBMIT_DELAY_SECONDS`.
- **A community GitHub Action instead of fastlane** — rejected: a second upload
  path outside the lanes, outside `DRY_RUN` and outside the redaction the lanes
  apply to credential-shaped arguments.
