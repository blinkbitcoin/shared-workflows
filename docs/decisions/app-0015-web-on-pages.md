# 15. The web target deploys to a Pages sub-path, tested as the same bytes

- **Status:** Accepted (refines [0006](https://github.com/blinkbitcoin/react-native-mobile-template/blob/main/docs/decisions/0006-web-opt-in.md)). The preview server is the shared tooling's `serve-dist` since 2026-10-01 (`pnpm exec serve-dist`); `scripts/e2e/serve-dist.mjs` is gone and the decision stands.
- **Date:** 2026-09-19

## Context

The first Pages deploy 404'd on every click: a project Pages site lives under
`/<repo>/`, the export wrote root-absolute paths, so the bundle never loaded.
`output: 'static'` also has no file for a dynamic route such as
`/details/42`, which Pages answers with its own 404. And the production
export bakes `.env.production`'s API URL, a host no test can reach, so the
first Playwright run against it rendered the error screen — PR runs never
saw that because a dev export points at the mock.

## Decision

Deploy under the sub-path, and test exactly the bytes that deploy.

- `app.config.ts` — `EXPO_PUBLIC_BASE_URL` becomes `experiments.baseUrl`;
  `.github/workflows/ci-web.yml` sets it to `/<repo>` on a deploy (empty with a
  custom domain, and on PR exports). `cd-production.yml`'s web job, which
  redeploys the site on a release dispatch, passes the same value;
  `scripts/ci-web-gate.test.mjs` holds the two together.
- `scripts/build-web.sh` — the export, then `+not-found.html` copied to
  `404.html`: Pages serves it for any unknown path and the router boots from
  the real URL.
- `scripts/e2e/serve-dist.mjs` — the preview server for Playwright, shaped
  like Pages: the base path, `/settings` from `settings.html`, `404.html`
  with a 404. `e2e/web/deep-link.spec.ts` opens `/details/42` cold.
- `e2e/web/fixtures.ts` — every `**/graphql` request is answered by the mock,
  whatever host the bundle was built for.
- `docs/release-runbook.md` — the `github-pages` environment needs a `v*` tag
  policy, since the deploy runs at the tag.

## Consequences

A deploy export used to be exercised for the first time at the tag, PR runs
using a dev export; amended 2026-09-19: every export is a production export,
so a PR tests the flavour that deploys (#36). Specs navigate with `./` paths because a leading `/` discards
the base path when Playwright joins it to `baseURL`. Pages is today's target,
not the interface: `Deploy` is deliberately not named for it.

## Alternatives

- **`web.output: 'single'`** — one HTML file, no static pre-render; the
  `404.html` copy gets the same effect and keeps the pre-rendered routes.
- **Rebuild the export for the test against the mock** — different bytes from
  the ones that deploy.
