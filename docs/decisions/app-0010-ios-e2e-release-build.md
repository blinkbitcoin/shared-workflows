# 10. iOS E2E runs a Release build, and opens the session's first URL itself

- **Status:** Accepted (supersedes [0009](app-0009-e2e-launch-by-deep-link.md) for iOS; Android keeps it)
- **Date:** 2026-09-17

## Context

The iOS suite never passed twice in a row on a runner. The dev-client path of
ADR 0009 needed four things to succeed every time — Metro up, a deep link
delivered, the iOS "Open in <app>?" prompt answered, a ~2000-module bundle
fetched over localhost before the dev client gave up — and three of the four
were seen to fail. The first Release run then exposed the trade: a Release
bundle resolves `.env.production` at build time, so the app shipped pointing
at a placeholder API host and the one flow that fetches data failed.

With that fixed, one flow still failed intermittently, and always the same
way: `deep-link` opened `rnmt://details/99`, our tap did land on **Open**,
iOS did create the `UIOpenURLAction` — and on a loaded runner the app acted on
it ~40 s later, after the flow had given up, pushing Details over whatever the
*next* flow was asserting. Three reported failures for one event, twice. The
same binary on a local simulator with the unified log streaming did the
hand-off in 40 ms, and showed the prompt exactly once in six opens: iOS
remembers the choice for the session. The session's first URL is the slow,
prompted one; every later one is alert-free and has never failed.

## Decision

CI builds the iOS E2E app as **Release** (`ios-configuration: Release` in
`.github/workflows/ci.yml`), passes the mock API URL into the build through
`environment-variables`, and `00-launch` opens the session's first URL itself on a link
that is a no-op on Home.

- `.github/workflows/ci.yml` — `ios-configuration: Release`;
  `environment-variables: '{"EXPO_PUBLIC_API_URL":"http://localhost:8082/graphql"}'` (a
  literal, because the build job runs before and apart from the job that
  starts the mock API; pinned to `scripts/ports.mjs` by `scripts/ports.test.mjs`).
- `.maestro/flows/00-launch.yaml` — after Home is visible, iOS only:
  `openLink: rnmt://`, an optional 20 s wait for `^Open$`, tap it, wait for
  Home again. The cost lands in the flow whose job is absorbing cold cost.
- `.maestro/helpers/to-tab-bar.yaml` — pops a pushed screen (iOS, optional)
  before a flow taps its tab, so one failure cannot cascade into every flow
  after it; used by `00-launch`, `home`, `details`, `settings`, `error-screen`.
- `.maestro/flows/deep-link.yaml` — `extendedWaitUntil` after each open, and
  the open + wait inside `retry`. Both are guards for the worst case, not the
  fix; the fix is the pre-warm above.
- `scripts/init.manifest.json` — `00-launch.yaml` carries the scheme token now.

## Consequences

The iOS suite no longer exercises the Metro dev path; Android (still Debug +
dev-client) is the only remaining coverage of it, and `src/config/env.ts`'s
`localhost` → `10.0.2.2` rewrite is `__DEV__`-only, so flipping Android to
Release needs that handled too. A change to `EXPO_PUBLIC_*` values reaches the
iOS E2E app only through `environment-variables`, never through a dotenv file — and the
value is folded into the `.app` cache key, so changing it rebuilds.

A flow that opens a URL must never be the first to do so in a session, and
must not assume the prompt appears: on a suite retry (same simulator boot) it
does not. When a deep link misbehaves again, `forensics-ios` now carries
`ios-unified.log` — SpringBoard's alert lifecycle and FrontBoard's
`UIOpenURLAction` hand-off — which is what settled this; read that before
reading screenshots.

A run marked green by GitHub can still hide a failed first attempt: the
suite is retried once, and the artifact carries the retry. The job log's
"rerunning the suite once" line is the signal; a first attempt that fails is
a failure to fix, not a pass.

## Alternatives

- **Keep Debug + dev-client and harden the launch** — rejected after three
  documented hypotheses each held for exactly one run.
- **A longer wait or a retry in `deep-link` alone** — tried; both guard the
  wrong thing, since the late navigation lands on the *next* flow.
- **Confirm the prompt with a waited tap instead of an optional one** — the
  tap was never the problem; it landed on Open every time.
