# Changelog

## [0.8.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.7.0...app-tooling-v0.8.0) (2026-10-01)


### Features

* **app-tooling:** a store-notes app suite, the environment-variables rule, and the chain tested here ([#184](https://github.com/blinkbitcoin/shared-workflows/issues/184)) ([3107d86](https://github.com/blinkbitcoin/shared-workflows/commit/3107d8652805aad5baa474e87c1d0da82f032004))

## [0.7.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.6.2...app-tooling-v0.7.0) (2026-10-01)


### Features

* **app-tooling:** ship check-skills, the runner for every skill's offline tests ([#179](https://github.com/blinkbitcoin/shared-workflows/issues/179)) ([5a20ec8](https://github.com/blinkbitcoin/shared-workflows/commit/5a20ec803a270d73b323ccf884b8986f642a9bb0))

## [0.6.2](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.6.1...app-tooling-v0.6.2) (2026-10-01)


### Bug Fixes

* **app-tooling:** accept nested pnpm peer suffixes and honour scripts-script ([#175](https://github.com/blinkbitcoin/shared-workflows/issues/175)) ([22ace35](https://github.com/blinkbitcoin/shared-workflows/commit/22ace35105e88cc22f897f852ecd11ab2f43ba46))
* **e2e:** launch the Android activity the package declares, not a guessed one ([#178](https://github.com/blinkbitcoin/shared-workflows/issues/178)) ([9018603](https://github.com/blinkbitcoin/shared-workflows/commit/9018603c1dbd1e8d0daedc3b49f4690b8381b298))

## [0.6.1](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.6.0...app-tooling-v0.6.1) (2026-10-01)


### Bug Fixes

* **app-tooling:** check the contract under the callers' working-directory ([#173](https://github.com/blinkbitcoin/shared-workflows/issues/173)) ([ba483bc](https://github.com/blinkbitcoin/shared-workflows/commit/ba483bcaaba1d2b3988d21337ff0b0bc3c7eb70c))
* **workflows:** close three gaps in the bare React Native support ([#170](https://github.com/blinkbitcoin/shared-workflows/issues/170)) ([5aaa33f](https://github.com/blinkbitcoin/shared-workflows/commit/5aaa33f42a6c9a6d3442ea214e8432aaa8419756))

## [0.6.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.5.0...app-tooling-v0.6.0) (2026-10-01)


### Features

* **workflows:** build a bare React Native app as well as an Expo one ([#167](https://github.com/blinkbitcoin/shared-workflows/issues/167)) ([c00ba1e](https://github.com/blinkbitcoin/shared-workflows/commit/c00ba1e4cab23b05aa6430fd0ebb988aea4adcdd))

## [0.5.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.4.0...app-tooling-v0.5.0) (2026-10-01)


### Features

* **workflows:** read a bare React Native app in the contract, check.yml and the scanners ([#164](https://github.com/blinkbitcoin/shared-workflows/issues/164)) ([fd83627](https://github.com/blinkbitcoin/shared-workflows/commit/fd83627d7282de334c20803574511a1e00d5f868))

## [0.4.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.3.0...app-tooling-v0.4.0) (2026-09-30)


### ⚠ BREAKING CHANGES

* **workflows:** a consumer's scripts/e2e/maestro-ios.sh and scripts/e2e/maestro-android.sh now fail the contract check (no-copy.e2e-suite), and scripts/e2e/serve-dist.mjs with its test fails no-copy.serve-dist. Run the package's e2e/ copies with your ports exported, and start the preview server as pnpm exec serve-dist.

### Features

* **workflows:** ship the Maestro suite runners and the web preview server for a laptop ([#161](https://github.com/blinkbitcoin/shared-workflows/issues/161)) ([0dafa26](https://github.com/blinkbitcoin/shared-workflows/commit/0dafa2652ae720f2fb04f0b0cdce030b599034a6))

## [0.3.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.2.0...app-tooling-v0.3.0) (2026-09-30)


### ⚠ BREAKING CHANGES

* **workflows:** a consumer's scripts/release/verify-*.sh, scripts/release/lib/verify-common.sh, scripts/setup/ and scripts/doctor.mjs now fail the contract check (no-copy.release-verify, no-copy.setup). Point the verify lanes at node_modules/@blinkbitcoin/app-tooling/release/ and run them from the repository root. Run setup from node_modules/@blinkbitcoin/app-tooling/setup/ and use `pnpm exec doctor`.

### Features

* **workflows:** ship the release verifiers, the machine setup and the doctor ([#158](https://github.com/blinkbitcoin/shared-workflows/issues/158)) ([334aa10](https://github.com/blinkbitcoin/shared-workflows/commit/334aa10ed60ae8f03348f671da5d8ac4ee42e0f1))

## [0.2.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.1.1...app-tooling-v0.2.0) (2026-09-30)


### ⚠ BREAKING CHANGES

* **workflows:** a consumer's scripts/security/ is now a no-copy.security failure in the contract check. Delete it, keep security-settings.json (add "rules" to jobs.code for your own Semgrep rules), and run the package's check-security locally. The file.security-* rows are gone.

### Features

* **workflows:** ship the security scanners instead of requiring each consumer to ([#155](https://github.com/blinkbitcoin/shared-workflows/issues/155)) ([92caa95](https://github.com/blinkbitcoin/shared-workflows/commit/92caa95b7028b3d3c2c4a55fca1cbccebce02127))

## [0.1.1](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.1.0...app-tooling-v0.1.1) (2026-09-30)


### Bug Fixes

* **app-tooling:** accept pnpm's peer suffix on the pinned lockfile entry ([#151](https://github.com/blinkbitcoin/shared-workflows/issues/151)) ([a335910](https://github.com/blinkbitcoin/shared-workflows/commit/a3359108e8e279d2cb22310a54522821ee133c44))

## [0.1.0](https://github.com/blinkbitcoin/shared-workflows/compare/app-tooling-v0.10.0...app-tooling-v0.1.0) (2026-09-30)


### ⚠ BREAKING CHANGES

* **workflows:** check-security.yml's `deps` input is `dependencies`, and the consumer's security settings program must print `dependencies=` instead of `deps=` (its `jobs.deps` key becomes `jobs.dependencies`).
* **workflows:** every caller renames its uses: paths, with: keys and the outputs it reads, and the consumer renames its package scripts and security files. check-code.yml, check-unit.yml, check-e2e.yml, check-codeql.yml and publish-promotion-retry.yml are check.yml, test-unit.yml, test-e2e.yml, check-code-scanning.yml and publish-retry.yml. Inputs: build-env and env-json -> environment-variables; xcode -> xcode-version; ios-signing and android-signing -> *-signing-enabled; release-meta-artifact -> build-info-artifact (default build-info); publish-store runner -> macos-enabled, ruby -> ruby-enabled, lane-args -> lane-arguments; publish-github-release tag -> release-tag; build-web playwright -> e2e, export-script -> build-script, export-args -> build-arguments, output-dir -> output-directory, playwright-browsers -> e2e-browsers; test-e2e maestro-flows, maestro-include-tags, maestro-exclude-tags -> flows, include-tags, exclude-tags, *-artifact-name -> *-artifact; test-unit test-script -> unit-script, scripts-test-script -> scripts-script; check-security openant -> review-codebase, sarif-upload -> sarif-upload-enabled; publish-badges render-script -> badges-script, badge-dir -> badge-directory; config-file -> configuration-file. Outputs: fp-ios/fp-android -> fingerprint-ios/ fingerprint-android, pr-release tag-name -> release-tag. The security settings file is security-settings.json, resolved by scripts/security/settings.mjs; the codebase review runner is scripts/security/review-codebase.sh. No alias is kept.
* **app-tooling:** the package's programs and exports are renamed: render-badges -> gen-badges, coverage-badge -> gen-coverage-badge, status-badge -> gen-status-badge, store-notes -> gen-store-notes, make-help -> help, check-consumer-contract -> check-contract. A consumer that runs any of them (pnpm exec, npx, a package.json script or a make recipe) calls the new name. No alias is kept.
* **app-tooling:** @blinkbitcoin/dev-config and @blinkbitcoin/expo-tooling are replaced by @blinkbitcoin/app-tooling. A consumer depends on github:blinkbitcoin/shared-workflows#<sha>&path:/packages/app-tooling, calls node_modules/@blinkbitcoin/app-tooling/... where it called node_modules/@blinkbitcoin/dev-config/..., imports @blinkbitcoin/app-tooling/expo/<preset> where it imported @blinkbitcoin/expo-tooling/<preset>, and renames dev-config.json to app-tooling.json.

### Miscellaneous

* **release:** pin the first published version to 0.1.0 ([bc44e7a](https://github.com/blinkbitcoin/shared-workflows/commit/bc44e7a600678bdaf20bc6c517ce7d2ec71ac395))


### Refactoring

* **app-tooling:** name every program and make target family-stem ([#143](https://github.com/blinkbitcoin/shared-workflows/issues/143)) ([a4bbdc0](https://github.com/blinkbitcoin/shared-workflows/commit/a4bbdc0c7d4d9f30ff08a02607ffbcadb05c4596))
* **app-tooling:** one package, @blinkbitcoin/app-tooling, replaces dev-config and expo-tooling ([#141](https://github.com/blinkbitcoin/shared-workflows/issues/141)) ([7e96f2e](https://github.com/blinkbitcoin/shared-workflows/commit/7e96f2ee6984ec34c355101f4a3e72b2383c27cc))
* **workflows:** dependencies, not deps, in every interface ([#145](https://github.com/blinkbitcoin/shared-workflows/issues/145)) ([b4bc2ee](https://github.com/blinkbitcoin/shared-workflows/commit/b4bc2ee0be478af0dc8ac1d6eedbe0015c8de656))
* **workflows:** one family-stem name per workflow, input, job and gate ([#144](https://github.com/blinkbitcoin/shared-workflows/issues/144)) ([bb1c403](https://github.com/blinkbitcoin/shared-workflows/commit/bb1c403a2c8ef96af9fb8d320233ff2cfa69fb69))

## [0.10.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.9.0...dev-config-v0.10.0) (2026-09-30)


### Features

* **dev-config:** hold every call and package to one shared-workflows commit ([#126](https://github.com/blinkbitcoin/shared-workflows/issues/126)) ([ea3454d](https://github.com/blinkbitcoin/shared-workflows/commit/ea3454d520d730d4a20b87d14786f1020a00128d))
* **dev-config:** hold every make recipe to one call of a tested script ([#128](https://github.com/blinkbitcoin/shared-workflows/issues/128)) ([bfad6fb](https://github.com/blinkbitcoin/shared-workflows/commit/bfad6fb5d549ebd42f19acd21fb00d36282fc310))
* **dev-config:** ship the i18n, codegen, secrets and CI lint checks for a laptop ([#127](https://github.com/blinkbitcoin/shared-workflows/issues/127)) ([f142e12](https://github.com/blinkbitcoin/shared-workflows/commit/f142e1249766cd62988062f510f2923dc36fa58f))

## [0.9.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.8.0...dev-config-v0.9.0) (2026-09-29)


### Features

* **dev-config:** block a consumer that holds a copy of what this family ships ([#118](https://github.com/blinkbitcoin/shared-workflows/issues/118)) ([3121715](https://github.com/blinkbitcoin/shared-workflows/commit/3121715a4b9eccb2814699b9956066c9ffa41076))
* **dev-config:** strict guard options, and build-info.sh --standalone for a laptop ([#119](https://github.com/blinkbitcoin/shared-workflows/issues/119)) ([7f2e619](https://github.com/blinkbitcoin/shared-workflows/commit/7f2e619b9aebd5ba08999804747f1a0d26c4c855))


### Bug Fixes

* **actions:** install Maestro from its checksummed release archive, not curl|bash ([#122](https://github.com/blinkbitcoin/shared-workflows/issues/122)) ([6497296](https://github.com/blinkbitcoin/shared-workflows/commit/6497296d09a9a63988c4bd0345000511a37e1c8c))

## [0.8.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.7.0...dev-config-v0.8.0) (2026-09-28)


### Features

* **ci:** publish a Security badge from check-security.yml's verdict ([#115](https://github.com/blinkbitcoin/shared-workflows/issues/115)) ([5586a23](https://github.com/blinkbitcoin/shared-workflows/commit/5586a23892557a3983342ea5adb260e3be0361ec))

## [0.7.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.6.0...dev-config-v0.7.0) (2026-09-28)


### Features

* **dev-config:** hold every call a consumer makes to the workflows' declared interfaces ([#105](https://github.com/blinkbitcoin/shared-workflows/issues/105)) ([4d0c337](https://github.com/blinkbitcoin/shared-workflows/commit/4d0c337f78823f5ee0f3e64b9e5450def0d960b9))
* **dev-config:** ship the release scripts a consumer runs on a laptop ([#109](https://github.com/blinkbitcoin/shared-workflows/issues/109)) ([aa03be4](https://github.com/blinkbitcoin/shared-workflows/commit/aa03be4b4e383b8193521c86c1e5d49ca2b01cc1))
* **dev-config:** ship the repository guards the template wrote ([#108](https://github.com/blinkbitcoin/shared-workflows/issues/108)) ([6e6cde1](https://github.com/blinkbitcoin/shared-workflows/commit/6e6cde16f487ee09f9c1ca8cea6dbf90f654be5e))

## [0.6.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.5.0...dev-config-v0.6.0) (2026-09-24)


### Features

* **workflows:** run the release-time security scanners in check-security.yml ([#82](https://github.com/blinkbitcoin/shared-workflows/issues/82)) ([521834e](https://github.com/blinkbitcoin/shared-workflows/commit/521834ee99e6ec5518873f9ee7fa7ff9be12cfe8))

## [0.5.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.4.0...dev-config-v0.5.0) (2026-09-24)


### Features

* **ci:** add check-security.yml, the reusable security scanning workflow ([#74](https://github.com/blinkbitcoin/shared-workflows/issues/74)) ([1c5bc73](https://github.com/blinkbitcoin/shared-workflows/commit/1c5bc7329bdfc9d889d898591b96f5fd3f5b9d1f))

## [0.4.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.3.1...dev-config-v0.4.0) (2026-09-23)


### ⚠ BREAKING CHANGES

* **workflows:** callers must update their uses: paths. checks.yml -> check-code.yml, unit.yml -> check-unit.yml, codeql.yml -> check-codeql.yml, e2e.yml -> check-e2e.yml, expo-prepare.yml -> build-prepare.yml, expo-build-ios.yml -> build-ios.yml, expo-build-android.yml -> build-android.yml, web.yml -> build-web.yml, badges.yml -> publish-badges.yml, expo-ota-publish.yml -> publish-ota.yml, fastlane-lane.yml -> publish-store.yml, github-release.yml -> publish-github-release.yml, release-pr-notes.yml -> pr-release-notes.yml. pr-title.yml and pr-closed.yml keep their names.

### Features

* **workflows:** prefix reusable workflow filenames by pipeline stage ([#64](https://github.com/blinkbitcoin/shared-workflows/issues/64)) ([aac1f48](https://github.com/blinkbitcoin/shared-workflows/commit/aac1f48afa437fa67d45bde742e2a05eced810bd))

## [0.3.1](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.3.0...dev-config-v0.3.1) (2026-09-23)


### Bug Fixes

* **checks:** add zizmor and a gitleaks history scan, and check every make ci gate runs in CI ([#62](https://github.com/blinkbitcoin/shared-workflows/issues/62)) ([20ee209](https://github.com/blinkbitcoin/shared-workflows/commit/20ee20946eba1aeab89150cbf1c403dab8736a30))

## [0.3.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.2.0...dev-config-v0.3.0) (2026-09-22)


### Features

* **checks:** answer "would these workflows work here?" without spending runners ([#56](https://github.com/blinkbitcoin/shared-workflows/issues/56)) ([f614b79](https://github.com/blinkbitcoin/shared-workflows/commit/f614b79108fdbf7a866fa08e9038e16ea8dc9397))

## [0.2.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.1.0...dev-config-v0.2.0) (2026-09-22)


### Features

* **checks:** report the whole consumer contract in one job, not one red at a time ([#51](https://github.com/blinkbitcoin/shared-workflows/issues/51)) ([2975b2f](https://github.com/blinkbitcoin/shared-workflows/commit/2975b2f79ed268b93d809d8d7bed9c94474679e9))

## [0.1.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.1.0...dev-config-v0.1.0) (2026-09-17)


### Features

* **dev-config:** one pinned tool table, checked instead of asserted ([#7](https://github.com/blinkbitcoin/shared-workflows/issues/7)) ([43e4b70](https://github.com/blinkbitcoin/shared-workflows/commit/43e4b70172272a631f87ace9d68de452e28e5b7c))


### Miscellaneous

* **release:** pin the first published version to 0.1.0 ([bc44e7a](https://github.com/blinkbitcoin/shared-workflows/commit/bc44e7a600678bdaf20bc6c517ce7d2ec71ac395))
