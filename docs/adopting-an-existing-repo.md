# Adopting these workflows into an existing app

Every other page here is written for a repository generated from
[`react-native-mobile-template`](https://github.com/blinkbitcoin/react-native-mobile-template),
which arrives satisfying the contract already. This one is for the other case:
an app that exists, was never generated from that template, and would like some
of these workflows anyway.

It is a supported case. A repository is allowed to use part of this family —
`check.yml` and `test-unit.yml` with nothing else is a perfectly good adoption, and
nothing here will tell you that you are missing Maestro flows for an E2E
workflow you never called.

## Start with the report, not this page

```sh
npx --package=@blinkbitcoin/app-tooling check-contract --skeleton
```

That prints what *your* repository is missing, with a fix per finding, and the
`package.json` fragment and caller toggles that would clear it. The table below
is the same information in the abstract; the command is the same information
about you. `check.yml` runs it as its first job, so this is also what CI will
say.

Before you have written a caller it has nothing to infer from, so name the
workflows you intend to use:

```sh
npx --package=@blinkbitcoin/app-tooling check-contract --profile checks,unit
```

## The two ways to satisfy a gate

Every default-on gate has a script name attached to it, and you have a choice
for each one:

- **Ship the script.** `"check:types": "tsc --noEmit"` in your `package.json`, and
  the gate runs it.
- **Turn the gate off** in your caller: `types: false`.

Neither is more correct. A repository that does not type-check should turn the
gate off rather than add a script that lies. What you should not do is leave a
default-on gate pointing at a script you do not have, because that is a red
check that never goes green.

Two of the names are house inventions rather than conventions — `check:docs`
and `check:licenses` — and they are the two most likely to surprise you, because
nothing else in the JavaScript world calls them that.

Seven have no fallback at all and fail rather than degrade: those two plus
`check:types`, `check:lint`, `check:format`, `check:unused` and `check:spell`. The table below marks
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
[`packages/app-tooling/contract.json`](../packages/app-tooling/contract.json), and
the block below is generated from it — the checker, this page and
[the consumer guide](consumer-guide.md) cannot disagree about what the contract
is.

"Optional — a fallback runs" means shared-workflows has its own implementation
and will use it. The gate still runs; it is just not the one you defined. That
is a warning in the report, not a failure. See
[Script contract](consumer-guide.md#script-contract) for why that seam exists.

<!-- contract-table:start -->

### If you call `check.yml`

| What | You need | Why |
| --- | --- | --- |
| `node` and `pnpm` in your mise config | required | the setup action, in every job of every workflow |
| `ruby` in your mise config | only if you set `release: true` | check.yml (release), and every fastlane lane workflow |
| `package.json` | required | every script gate, through scripts/checks/run-script.sh |
| `pnpm-lock.yaml` | required | the setup action (pnpm install --frozen-lockfile), and scripts/ci/native-hash.sh |
| `check:types` | required, or pass `types: false` | check.yml (types) |
| `check:lint` | required, or pass `lint: false` | check.yml (lint) |
| `check:format` | required, or pass `format: false` | check.yml (format) |
| `check:unused` | required, or pass `unused: false` | check.yml (unused) |
| `check:spell` | required, or pass `spell: false` | check.yml (spell) |
| `check:docs` | required, or pass `docs: false` | check.yml (docs) |
| `check:licenses` | required, or pass `licenses: false` | check.yml (licenses) |
| `check:expo-health` | optional — a fallback runs (Expo apps only) | check.yml (expo-health) |
| `check:audit` | optional — a fallback runs | check.yml (audit) |
| `check:ci` | optional — a fallback runs | check.yml (ci) |
| `check:secrets` | optional — a fallback runs | check.yml (secrets) |
| `check:generated` | optional — a fallback runs | check.yml (generated) |
| `check:prebuild` | only if you set `prebuild: true` | check.yml (prebuild) |
| `check:release` | only if you set `release: true` | check.yml (release) |
| `@commitlint/cli` | optional — a fallback runs | check.yml (commits), pr-title.yml |
| `Gemfile` | only if you set `release: true` | check.yml (release) via bundler-cache, and scripts/release/fastlane.sh |
| every gate CI runs, reachable from `make ci` | required | check.yml and test-unit.yml, against your Makefile |
| every gate `make ci` runs, run by CI | required | your Makefile, against check.yml and test-unit.yml |
| no `scripts/setup`, `scripts/doctor.mjs` or `scripts/doctor.test.mjs` | required | the machine setup (setup/*.sh) and the doctor (bin/doctor.mjs, doctor.requirements.json) @blinkbitcoin/app-tooling ships; a copy in your repository is compared with them by nothing and drifts |
| `biome.json` | optional — a fallback runs | your own lint gate, which walks the whole tree |
| `eslint.config.mjs` | optional — a fallback runs | your own lint gate, which walks the whole tree |
| `tsconfig.json` | optional — a fallback runs | your own type check gate |
| `knip.json` | optional — a fallback runs | your own unused-code gate |
| `typos.toml` | optional — a fallback runs | your own spell gate |
| `.gitignore` | optional — a fallback runs | your own working tree |
| no `scripts/check-coverage-empty.mjs`, `scripts/check-coverage-empty.test.mjs` or `scripts/fixtures/coverage-summary.json` | required | the check-coverage-empty program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/check-diagrams.mjs` or `scripts/check-diagrams.test.mjs` | required | the check-diagrams program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/check-docs-tables.mjs` or `scripts/check-docs-tables.test.mjs` | required | the check-docs-tables program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/make-target-names.test.mjs` | required | the check-make-target-names program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/shell-locale.test.mjs` | required | the check-shell-locale program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/workflow-names.test.mjs` | required | the check-workflow-names program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/release/resolve-version.sh` or `scripts/release/resolve-version.test.mjs` | required | release/resolve-version.sh, which @blinkbitcoin/app-tooling ships and build-prepare.yml runs; a copy in your repository is compared with it by nothing and drifts |
| one shared-workflows commit for every call, package and lockfile entry | required | every call and every package of this family, read at one commit: a pin bump that moves the workflows and not the packages runs CI on one commit and a laptop on another |
| no `scripts/tooling-pin.mjs` or `scripts/tooling-pin.test.mjs` | required | the fix-tooling-pin program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/lib/workflow-calls.mjs`, `scripts/lib/workflow-calls.test.mjs` or `scripts/workflow-contract.test.mjs` | required | check-contract, which @blinkbitcoin/app-tooling ships: its one-pin row holds the pins and its call rows hold every call to its workflow's interface |
| no `scripts/check-lockfile.sh` or `scripts/check-lockfile.test.mjs` | required | the check-lockfile program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/release/build-info.sh`, `scripts/release/build-info.test.mjs` or `scripts/release/shared-copies.test.mjs` | required | release/build-info.sh, which @blinkbitcoin/app-tooling ships and build-prepare.yml runs; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/check-i18n.sh` or `scripts/check-codegen.sh` | required | checks/generated.sh, which @blinkbitcoin/app-tooling ships and check.yml runs; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/shellcheck.sh` | required | ci/check-ci.sh, which @blinkbitcoin/app-tooling ships and check.yml runs: actionlint, zizmor and shellcheck at the pinned versions |
| no `scripts/release/notes.mjs`, `scripts/release/notes.test.mjs`, `scripts/release/llm/index.mjs`, `scripts/release/llm/index.test.mjs`, `scripts/release/fixtures/release-body.md`, `scripts/release/fixtures/release-pr-body.md`, `scripts/release/fixtures/anthropic-response.json`, `scripts/release/fixtures/anthropic-invalid-response.json` or `scripts/release/fixtures/openai-response.json` | required | the gen-store-notes program @blinkbitcoin/app-tooling ships, which build-prepare.yml and pr-store-notes.yml run through scripts/release/gen-store-notes.sh; a copy in your repository is not run, and drifts |
| no `scripts/lib/llm/index.mjs`, `scripts/lib/llm/index.test.mjs`, `scripts/lib/llm/anthropic.mjs`, `scripts/lib/llm/anthropic.test.mjs`, `scripts/lib/llm/openai.mjs`, `scripts/lib/llm/openai.test.mjs`, `scripts/lib/llm/request.mjs` or `scripts/lib/llm/request.test.mjs` | required | the provider-portable LLM adapters @blinkbitcoin/app-tooling ships (@blinkbitcoin/app-tooling/llm and /llm-request), which its gen-store-notes program uses; a copy in your repository is compared with them by nothing and drifts |
| no `scripts/test-siblings.test.mjs` | required | the check-test-siblings program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/worktree-ignores.test.mjs` | required | the check-ignored-directories program @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/check-docs.sh`, `scripts/check-docs.test.mjs`, `scripts/manifest-structural.mjs` or `scripts/manifest-structural.test.mjs` | required | the check-docs program @blinkbitcoin/app-tooling ships, which runs check-make-target-names, check-docs-tables and check-diagrams after its own two checks; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/check-licenses.mjs` or `scripts/check-licenses.test.mjs` | required | the check-licenses program @blinkbitcoin/app-tooling ships, with the organisation's license allowlist; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/codeql-local.sh`, `scripts/codeql-local.test.mjs`, `scripts/codeql-findings.mjs` or `scripts/codeql-findings.test.mjs` | required | the check-code-scanning program @blinkbitcoin/app-tooling ships, which reads the same configuration file check-code-scanning.yml does; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/hooks/install-if-lockfile-changed.sh` or `scripts/hooks/install-if-lockfile-changed.test.mjs` | required | hooks/install-if-lockfile-changed.sh, which @blinkbitcoin/app-tooling ships; a copy in your repository is compared with it by nothing and drifts |
| no `scripts/check-deps.sh` or `scripts/check-deps.test.mjs` | required | checks/expo-health.sh, which @blinkbitcoin/app-tooling ships and check.yml runs when you have no check:expo-health: advisory SDK drift, then expo-doctor; a copy in your repository is compared with it by nothing and drifts |

### If you call `test-unit.yml`

| What | You need | Why |
| --- | --- | --- |
| `test:coverage` | required, or pass `coverage: false` | test-unit.yml (coverage-script) |
| `test:scripts` | required | test-unit.yml (scripts-script) |
| `jest.config.ts` | optional — a fallback runs | test-unit.yml, which runs your test script over the whole tree |

### If you call `test-e2e.yml`

| What | You need | Why |
| --- | --- | --- |
| `app.config.ts`, `app.config.js`, `app.config.cjs` or `app.json` | required (Expo apps only) | test-e2e.yml and every build workflow, through scripts/lib/expo-config.sh |
| `.maestro` | required | test-e2e.yml (flows) |
| `ios`, committed to git | only if you set `ios: true` (bare React Native apps only) | test-e2e.yml's iOS build, on the bare stack |
| `android`, committed to git | required, or pass `android: false` (bare React Native apps only) | test-e2e.yml's Android build, on the bare stack |
| `test-e2e.yml:e2e-setup-script` and `test-e2e.yml:e2e-teardown-script` | required | test-e2e.yml, through scripts/e2e/run-hook.sh |
| no `scripts/e2e/maestro-ios.sh` or `scripts/e2e/maestro-android.sh` | required | the Maestro suite runners test-e2e.yml runs (scripts/e2e/ios-maestro.sh and android-maestro.sh, with app-launch.sh and ios-simulator.sh) and @blinkbitcoin/app-tooling ships under e2e/; a local copy launches and runs the flows its own way and drifts from what CI runs |

### If you call `build-web.yml`

| What | You need | Why |
| --- | --- | --- |
| `build:web` | required | build-web.yml (build-script) |
| `test:e2e:web` | required, or pass `e2e: false` | build-web.yml (e2e) |
| `@playwright/test` | required, or pass `e2e: false` | build-web.yml, through scripts/web/playwright-version.sh |
| no `scripts/e2e/serve-dist.mjs` or `scripts/e2e/serve-dist.test.mjs` | required | the serve-dist program @blinkbitcoin/app-tooling ships, the preview server the expo/playwright preset starts; a copy in your repository is compared with it by nothing and drifts |

### If you call `publish-badges.yml`

| What | You need | Why |
| --- | --- | --- |
| no `scripts/badges/badge.mjs`, `scripts/badges/badge.test.mjs`, `scripts/badges/coverage-badge.mjs`, `scripts/badges/coverage-badge.test.mjs`, `scripts/badges/render.mjs`, `scripts/badges/render.test.mjs`, `scripts/badges/security-badge.mjs`, `scripts/badges/security-badge.test.mjs`, `scripts/badges/status-badge.mjs` or `scripts/badges/status-badge.test.mjs` | required | the gen-badges program @blinkbitcoin/app-tooling ships and publish-badges.yml runs; a copy in your repository is compared with it by nothing and drifts |

### If you call `check-code-scanning.yml`

| What | You need | Why |
| --- | --- | --- |
| `.github/codeql/codeql-config.yml` | optional — a fallback runs | check-code-scanning.yml (configuration-file) |

### If you call `check-security.yml`

| What | You need | Why |
| --- | --- | --- |
| no `scripts/security` | required | the scanners, the settings resolver and the verdict check-security.yml runs from this family (scripts/security/, packages/app-tooling/lib/security-*.mjs) and @blinkbitcoin/app-tooling ships as check-security; a copy in your repository is run by nothing and drifts |
| `security-settings.json` | optional — a fallback runs | the settings resolver (packages/app-tooling/lib/security-settings.mjs) the Settings job and every runner read it with |

### If you call the release workflows

| What | You need | Why |
| --- | --- | --- |
| `fastlane/Fastfile` | required | build-ios.yml, build-android.yml, publish-store.yml |
| the `ios:build`, `ios:verify`, `android:build` and `android:verify` lanes | required | build-ios.yml, build-android.yml |
| lanes that read only these `APP_REVIEW_*` names: `APP_REVIEW_DEMO_PASSWORD`, `APP_REVIEW_DEMO_USER`, `APP_REVIEW_EMAIL`, `APP_REVIEW_FIRST_NAME`, `APP_REVIEW_LAST_NAME`, `APP_REVIEW_NOTES` and `APP_REVIEW_PHONE` | required | publish-store.yml, which passes exactly these as secrets |
| no `scripts/release/verify-ios.sh`, `scripts/release/verify-android.sh`, `scripts/release/lib/verify-common.sh` or `scripts/release/verify.test.mjs` | required | the release verifiers @blinkbitcoin/app-tooling ships as release/verify-ios.sh and release/verify-android.sh (with lib/verify-common.sh), which your verify lanes run; a copy in your repository is compared with them by nothing and drifts |
| `@expo/fingerprint` | required (Expo apps only) | build-prepare.yml and publish-ota.yml, through scripts/lib/release-env.sh |
| `ios`, committed to git | required (bare React Native apps only, when you call `build-ios.yml`) | build-ios.yml, on the bare stack |
| `android`, committed to git | required (bare React Native apps only, when you call `build-android.yml`) | build-android.yml, on the bare stack |

<!-- contract-table:end -->

## Things that are not scripts

**The toolchain.** These workflows install node and pnpm with
[mise](https://mise.jdx.dev), from a `.mise.toml` in your repository. There is
no npm or yarn path, and no `.nvmrc` support: the lockfile is read directly,
before any install, to compute the native cache key. A repository on a different
package manager is the one case this family cannot accommodate.

**The `.workflows/` checkout.** Every job checks this repository out into
`.workflows/` beside yours. Any tool of yours that walks the whole tree will
find it and lint, type-check or test files you do not own — a red Unit job over
our files is the usual first symptom. The
[ignore list](consumer-guide.md#workflows-ignore-list-for-consumers) is seven
entries; the report checks all seven, and skips the ones whose config file you
do not have.

**Expo or bare React Native.** The report judges your repository as one
native stack and says which on its first line: `expo` when `package.json` lists
`expo` and git tracks no `ios/`, `bare` otherwise, or whatever your callers'
`native-stack` input says
([Expo or bare React Native](consumer-guide.md#expo-or-bare-react-native)).
The rows above marked for one stack are skipped on the other. A bare app is
held to the `ios/` and `android/` it commits instead of an Expo config, skips
the `expo-health` gate, and is scanned by `check-security.yml` from those
projects and `react-native bundle`. `test-e2e.yml` and the release workflows
build either stack: see the next section.

## A bare React Native app

A React Native app that is not an Expo app — `ios/` and `android/` committed,
no `expo` dependency, `react-native start` for Metro, no dev client — can call
every workflow here, `test-e2e.yml` and the release workflows included. What it
needs:

- **pnpm and mise.** The same as an Expo app: a `.mise.toml` pinning node and
  pnpm (and Ruby, Java for Android), and a `pnpm-lock.yaml` at the root. The
  workflows read the lockfile before any install.
- **Its native projects committed.** `ios/` with a single `*.xcworkspace` and
  `android/` with `android/app/build.gradle` (or `.kts`). Nothing is generated:
  the prebuild step only checks they are there and tracked, and fails with the
  fix when they are not. Keep `ios/Pods/` and the build directories ignored.
- **Literal identifiers, or the inputs.** The bundle identifier comes from
  `xcodebuild -showBuildSettings` (or the `project.pbxproj`), the application id
  from `applicationId` in `build.gradle` (with the debug build type's
  `applicationIdSuffix` for the E2E build, which is a debug one), the URL scheme
  from `Info.plist` or the manifest. Where a workflow takes `ios-bundle-id`,
  `android-package` or `ios-scheme`, `test-e2e.yml` included, those win.
- **`native-stack: bare`** on the native callers. Detection gets it right
  without (no `expo` dependency), but naming it keeps the app on the bare path
  if it later adds an Expo module.
- **`dev-client: false`** on `test-e2e.yml`: there is no dev-client launcher,
  so the app is launched plainly and loads `index.bundle` from Metro.
- **A `fastlane/` at the root**, or the `fastlane-directory` input pointing at
  one deeper in the repository (it must be named `fastlane`).

The fingerprint `build-prepare.yml` records is then a sha256 over the tracked
native files and the lockfile rather than `@expo/fingerprint`'s, under the same
names. The per-stack table and caller examples are in the consumer guide's
[Expo or bare](consumer-guide.md#expo-or-bare); `test/fixtures/consumer-bare/`
in this repository is the smallest such app the tests run against.

## Check it before you push

```sh
# what CI will say
npx --package=@blinkbitcoin/app-tooling check-contract
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
