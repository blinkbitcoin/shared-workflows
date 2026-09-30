# Changelog

## [0.11.0](https://github.com/blinkbitcoin/shared-workflows/compare/dev-config-v0.10.0...dev-config-v0.11.0) (2026-09-30)


### Features

* **dev-config:** ship the badge renderer, and render publish-badges.yml's badges with it ([#132](https://github.com/blinkbitcoin/shared-workflows/issues/132)) ([97fba35](https://github.com/blinkbitcoin/shared-workflows/commit/97fba358bdf1085dccadc95bb73a050e83591965))
* **dev-config:** ship the store notes generator and run it for every consumer ([#133](https://github.com/blinkbitcoin/shared-workflows/issues/133)) ([5c937a1](https://github.com/blinkbitcoin/shared-workflows/commit/5c937a1bc10494d9586137a7e65094b51a4935bc))

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
