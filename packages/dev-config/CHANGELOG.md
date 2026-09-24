# Changelog

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
