# Adopting these workflows into an existing app

Every other page here is written for a repository generated from
[`react-native-mobile-template`](https://github.com/blinkbitcoin/react-native-mobile-template),
which arrives satisfying the contract already. This one is for the other case:
an app that exists, was never generated from that template, and would like some
of these workflows anyway.

It is a supported case. A repository is allowed to use part of this family —
`check-code.yml` and `check-unit.yml` with nothing else is a perfectly good adoption, and
nothing here will tell you that you are missing Maestro flows for an E2E
workflow you never called.

## Start with the report, not this page

```sh
npx --package=@blinkbitcoin/dev-config check-consumer-contract --skeleton
```

That prints what *your* repository is missing, with a fix per finding, and the
`package.json` fragment and caller toggles that would clear it. The table below
is the same information in the abstract; the command is the same information
about you. `check-code.yml` runs it as its first job, so this is also what CI will
say.

Before you have written a caller it has nothing to infer from, so name the
workflows you intend to use:

```sh
npx --package=@blinkbitcoin/dev-config check-consumer-contract --profile checks,unit
```

## The two ways to satisfy a gate

Every default-on gate has a script name attached to it, and you have a choice
for each one:

- **Ship the script.** `"typecheck": "tsc --noEmit"` in your `package.json`, and
  the gate runs it.
- **Turn the gate off** in your caller: `typecheck: false`.

Neither is more correct. A repository that does not typecheck should turn the
gate off rather than add a script that lies. What you should not do is leave a
default-on gate pointing at a script you do not have, because that is a red
check that never goes green.

Two of the names are house inventions rather than conventions — `check:docs`
and `deps:licenses` — and they are the two most likely to surprise you, because
nothing else in the JavaScript world calls them that.

Seven have no fallback at all and fail rather than degrade: those two plus
`typecheck`, `lint`, `format:check`, `knip` and `spell`. The table below marks
each one.

## Start from the smallest working consumer

[`test/fixtures/consumer-min/`](../test/fixtures/consumer-min) is the smallest
repository that satisfies this contract: a `package.json` whose every contract
script is a no-op, an eleven-line `.mise.toml`, an `app.config.ts`, the seven
[`.workflows/` ignore entries](consumer-guide.md#workflows-ignore-list-for-consumers),
and the caller workflows from the consumer guide. It exists so the contract can be
tested without a real app, which makes it exactly the right thing to copy from
when you are wiring one up — replace each no-op with what your repository
actually does, and delete the callers you do not want.

## What each workflow needs

The definitive version of this table is
[`packages/dev-config/contract.json`](../packages/dev-config/contract.json), and
the block below is generated from it — the checker, this page and
[the consumer guide](consumer-guide.md) cannot disagree about what the contract
is.

"Optional — a fallback runs" means shared-workflows has its own implementation
and will use it. The gate still runs; it is just not the one you defined. That
is a warning in the report, not a failure. See
[Script contract](consumer-guide.md#script-contract) for why that seam exists.

<!-- contract-table:start -->

### If you call `check-code.yml`

| What | You need | Why |
| --- | --- | --- |
| `node` and `pnpm` in your mise config | required | the setup action, in every job of every workflow |
| `ruby` in your mise config | only if you set `release-checks: true` | check-code.yml (release-checks), and every fastlane lane workflow |
| `package.json` | required | every script gate, through scripts/checks/run-script.sh |
| `pnpm-lock.yaml` | required | the setup action (pnpm install --frozen-lockfile), and scripts/ci/native-hash.sh |
| `typecheck` | required, or pass `typecheck: false` | check-code.yml (typecheck) |
| `lint` | required, or pass `lint: false` | check-code.yml (lint) |
| `format:check` | required, or pass `format: false` | check-code.yml (format) |
| `knip` | required, or pass `knip: false` | check-code.yml (knip) |
| `spell` | required, or pass `spell: false` | check-code.yml (spell) |
| `check:docs` | required, or pass `docs-check: false` | check-code.yml (docs-check) |
| `deps:licenses` | required, or pass `licenses: false` | check-code.yml (licenses) |
| `deps:check` | optional — a fallback runs | check-code.yml (expo-doctor) |
| `deps:audit` | optional — a fallback runs | check-code.yml (audit) |
| `check:ci` | optional — a fallback runs | check-code.yml (actionlint, shellcheck) |
| `check:secrets` | optional — a fallback runs | check-code.yml (secret-scan) |
| `i18n:check` | optional — a fallback runs | check-code.yml (i18n) |
| `codegen:check` | optional — a fallback runs | check-code.yml (graphql-codegen) |
| `check-prebuild` | only if you set `prebuild-check: true` | check-code.yml (prebuild-check) |
| `check:bundle-secrets` | only if you set `bundle-secrets: true` | check-code.yml (bundle-secrets) |
| `check:release` | only if you set `release-checks: true` | check-code.yml (release-checks) |
| `@commitlint/cli` | optional — a fallback runs | check-code.yml (commitlint), pr-title.yml |
| `Gemfile` | only if you set `release-checks: true` | check-code.yml (release-checks) via bundler-cache, and scripts/release/fastlane.sh |
| every gate CI runs, reachable from `make ci` | required | check-code.yml and check-unit.yml, against your Makefile |
| every gate `make ci` runs, run by CI | required | your Makefile, against check-code.yml and check-unit.yml |
| `biome.json` | optional — a fallback runs | your own lint gate, which walks the whole tree |
| `eslint.config.mjs` | optional — a fallback runs | your own lint gate, which walks the whole tree |
| `tsconfig.json` | optional — a fallback runs | your own typecheck gate |
| `knip.json` | optional — a fallback runs | your own knip gate |
| `typos.toml` | optional — a fallback runs | your own spell gate |
| `.gitignore` | optional — a fallback runs | your own working tree |

### If you call `check-unit.yml`

| What | You need | Why |
| --- | --- | --- |
| `test:coverage` | required, or pass `coverage: false` | check-unit.yml (coverage-script) |
| `test:scripts` | required | check-unit.yml (scripts-test-script) |
| `jest.config.ts` | optional — a fallback runs | check-unit.yml, which runs your test script over the whole tree |

### If you call `check-e2e.yml`

| What | You need | Why |
| --- | --- | --- |
| `app.config.ts`, `app.config.js`, `app.config.cjs` or `app.json` | required | check-e2e.yml and every build workflow, through scripts/lib/expo-config.sh |
| `.maestro` | required | check-e2e.yml (maestro-flows) |
| `check-e2e.yml:e2e-setup-script` and `check-e2e.yml:e2e-teardown-script` | required | check-e2e.yml, through scripts/e2e/run-hook.sh |

### If you call `build-web.yml`

| What | You need | Why |
| --- | --- | --- |
| `build:web` | required | build-web.yml (export-script) |
| `test:e2e:web` | required, or pass `playwright: false` | build-web.yml (e2e-script) |
| `@playwright/test` | required, or pass `playwright: false` | build-web.yml, through scripts/web/playwright-version.sh |

### If you call `publish-badges.yml`

| What | You need | Why |
| --- | --- | --- |
| `badges:render` | required | publish-badges.yml (render-script) |

### If you call `check-codeql.yml`

| What | You need | Why |
| --- | --- | --- |
| `.github/codeql/codeql-config.yml` | optional — a fallback runs | check-codeql.yml (config-file) |

### If you call `check-security.yml`

| What | You need | Why |
| --- | --- | --- |
| `scripts/security/config.mjs` | required | check-security.yml (the Config job), through scripts/security/settings.sh |
| `scripts/security/deps.sh` | required, or pass `deps: false` | check-security.yml (deps), through scripts/security/run-job.sh |
| `scripts/security/code.sh` | required, or pass `code: false` | check-security.yml (code), through scripts/security/run-job.sh |
| `scripts/security/policy.sh` | required, or pass `policy: false` | check-security.yml (policy), through scripts/security/run-job.sh |
| `scripts/security/sbom.sh` | only if you set `sbom: true` | check-security.yml (sbom), through scripts/security/run-job.sh |
| `scripts/security/bundle.sh` | only if you set `bundle: true` | check-security.yml (bundle), through scripts/security/run-job.sh |
| `scripts/security/mobile.sh` | only if you set `mobile: true` | check-security.yml (mobile), through scripts/security/run-job.sh |
| `scripts/security/binaries.sh` | only if you set `binaries: true` | check-security.yml (binaries), through scripts/security/run-job.sh |
| `scripts/security/review.sh` | only if you set `review: true` | check-security.yml (review), through scripts/security/run-job.sh |
| `scripts/security/openant.sh` | only if you set `openant: true` | check-security.yml (openant), through scripts/security/run-job.sh |
| `scripts/security/verdict.mjs` | required | check-security.yml (the Verdict job), through scripts/security/verdict.sh |
| `security-policy.json` | optional — a fallback runs | scripts/security/config.mjs, the settings resolver the Config job runs |

### If you call the release workflows

| What | You need | Why |
| --- | --- | --- |
| `fastlane/Fastfile` | required | build-ios.yml, build-android.yml, publish-store.yml |
| the `ios:build`, `ios:verify`, `android:build` and `android:verify` lanes | required | build-ios.yml, build-android.yml |
| lanes that read only these `APP_REVIEW_*` names: `APP_REVIEW_DEMO_PASSWORD`, `APP_REVIEW_DEMO_USER`, `APP_REVIEW_EMAIL`, `APP_REVIEW_FIRST_NAME`, `APP_REVIEW_LAST_NAME`, `APP_REVIEW_NOTES` and `APP_REVIEW_PHONE` | required | publish-store.yml, which passes exactly these as secrets |
| `scripts/release/verify-ios.sh` | required | the ios verify lane |
| `scripts/release/verify-android.sh` | required | the android verify lane |
| `scripts/release/notes.mjs` | optional — a fallback runs | build-prepare.yml, through scripts/release/notes.sh |
| `@expo/fingerprint` | required | build-prepare.yml and publish-ota.yml, through scripts/lib/release-env.sh |

<!-- contract-table:end -->

## Things that are not scripts

**The toolchain.** These workflows install node and pnpm with
[mise](https://mise.jdx.dev), from a `.mise.toml` in your repository. There is
no npm or yarn path, and no `.nvmrc` support: the lockfile is read directly,
before any install, to compute the native cache key. A repository on a different
package manager is the one case this family cannot accommodate.

**The `.workflows/` checkout.** Every job checks this repository out into
`.workflows/` beside yours. Any tool of yours that walks the whole tree will
find it and lint, typecheck or test files you do not own — a red Unit job over
our files is the usual first symptom. The
[ignore list](consumer-guide.md#workflows-ignore-list-for-consumers) is seven
entries; the report checks all seven, and skips the ones whose config file you
do not have.

**Expo.** `check-e2e.yml` and every release workflow prebuild an Expo app and read
`expo config --json` for the app name, scheme, bundle identifier and package.
They are Expo-specific in a way `check-code.yml` and `check-unit.yml` are not. A React
Native app that is not an Expo app can use the first two and should not call the
rest.

## Check it before you push

```sh
# what CI will say
npx --package=@blinkbitcoin/dev-config check-consumer-contract
```

And when you want the real thing rather than a prediction, the
[Smoke](../.github/workflows/self-smoke.yml) workflow in this repository takes
any repository and ref:

```sh
gh workflow run self-smoke.yml -R blinkbitcoin/shared-workflows \
  -f repository=your-org/your-app -f ref=main -f contract-only=true
```

`contract-only=true` runs the contract check against your repository and stops
there — seconds, and no runners spent on gates that cannot pass yet. Drop it to
run the full suite. A private repository needs a `SMOKE_TOKEN` secret; see
[Secrets policy](consumer-guide.md#secrets-policy).

## Then read the contract

[`consumer-guide.md`](consumer-guide.md) is the full contract: every input,
output and secret, the caller examples to copy, and the
[gotchas encoded](consumer-guide.md#gotchas-encoded) — forty-odd hard-won CI
lessons and exactly where each one lives, which is the part worth reading even
if you never adopt any of this.
