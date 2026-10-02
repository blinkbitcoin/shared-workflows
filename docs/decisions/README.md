# App architecture decisions

The decisions behind the CI, release and tooling half of the React Native app
template, which now lives here with the workflows and the package they shaped.
Each record states the forces, the decision, what it costs, and the files that
embody it. The files they cite are in
[blinkbitcoin/react-native-mobile-template](https://github.com/blinkbitcoin/react-native-mobile-template)
(at the time of writing; an ADR is history, so a path may since have moved into
this repository) or here.

They keep the numbers they had in the template, behind an `app-` prefix, so a
reference to "ADR 0023" still finds one record. The template keeps 0001 to 0006,
the decisions about the app itself (Expo CNG, Biome and ESLint, theming, Lingui,
Apollo, web as an opt-in target), and an index line for each record moved here.
New decisions about this repository's own workflows and tooling are numbered
from their own series, without the prefix.

| ADR | Decision | Date |
|---|---|---|
| [0007](app-0007-mise-not-nix.md) | `mise` pins the toolchain for humans and CI, not Nix | 2026-09-05 |
| [0008](app-0008-release-please-and-store-notes.md) | release-please in manifest mode owns versioning; store notes are generated prose | 2026-09-05 |
| [0009](app-0009-e2e-launch-by-deep-link.md) | E2E foregrounds the dev client by deep link; the launcher's Bonjour discovery never works | 2026-09-06 |
| [0010](app-0010-ios-e2e-release-build.md) | iOS E2E runs a Release build and opens the session's first URL itself; Android keeps 0009 | 2026-09-17 |
| [0011](app-0011-release-chain-by-dispatch.md) | release-please starts beta, web and the release PR's CI by `workflow_dispatch`; no GitHub App | 2026-09-18 |
| [0012](app-0012-expo-sdk-drift-is-advisory.md) | Expo SDK patch drift is a warning; `minimumReleaseAge` alone decides when a patch comes in | 2026-09-18 |
| [0013](app-0013-per-commit-queues.md) | CI on `main` and the internal release queue per commit; only store-touching jobs share the `release` queue | 2026-09-19 |
| [0014](app-0014-green-gate-heals-itself.md) | Beta's green gate dispatches the internal build it is missing instead of waiting for a human | 2026-09-19 |
| [0015](app-0015-web-on-pages.md) | The web target deploys to a Pages sub-path, with a 404 shell for deep links, tested as the same bytes | 2026-09-19 |
| [0016](app-0016-job-names-by-purpose.md) | Workflow and job names say what a step is for, in store vocabulary, never a tool's | 2026-09-19 |
| [0017](app-0017-build-tag-reserved-at-push.md) | The `-build.N` tag is created in Prepare at push time, while the commit is still main's tip;<br>GitHub refuses a later tag once a workflow file changed | 2026-09-19 |
| [0018](app-0018-store-listing-sync-lane.md) | Additive `sync_metadata`/`pull_metadata` lanes edit the store listing outside a release,<br>gated behind `STORE_METADATA_SYNC_ENABLED`; `release_production` is unchanged | 2026-09-19 |
| [0019](app-0019-huawei-appgallery-release-lane.md) | Huawei AppGallery joins at the release tier as an additive `upload_huawei` lane behind<br>`HUAWEI_UPLOADS_ENABLED`; the binary only, the listing stays console-only | 2026-09-20 |
| [0020](app-0020-huawei-joins-every-tier.md) | AppGallery runs on the internal, beta and release tiers behind the same toggle;<br>one version slot makes a tier a submit flag, and a busy slot skips rather than fails | 2026-09-21 |
| [0021](app-0021-store-notes-drafted-on-the-release-pr.md) | The store notes are drafted once into the release PR body for review, and every tier<br>ships that text; the prompt is `store-notes.prompt.md`; the LLM runs in that one job | 2026-09-22 |
| [0022](app-0022-security-scanning-before-release.md) | Scanners write SARIF, one verdict step applies the threshold; placed by what each<br>check reads; deterministic scanners can block, an LLM reviewer only annotates | 2026-09-24 |
| [0023](app-0023-cd-verified-before-release.md) | Every shared-workflows call is pinned to one commit SHA that Dependabot moves;<br>a PR runs the CD calls and the store-notes chain against that pin | 2026-09-26 |
| [0024](app-0024-shared-tooling-at-the-workflows-pin.md) | The shared tooling package is a git dependency on shared-workflows at the workflows pin;<br>the lockfile gate allows that one source, and a test holds the two commits together | 2026-09-27 |
| [0025](app-0025-security-scanners-from-the-shared-tooling.md) | The security scanners, resolver and verdict are shared-workflows' own, run here through the package's<br>`check-security`; this repository keeps only `security-settings.json` and the files it names | 2026-09-30 |
