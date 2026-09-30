:robot: I have created a release *beep* *boop*
---

## [0.8.0](https://github.com/acme/app/compare/v0.7.0...v0.8.0) (2026-09-24)

### Features

* **tooling:** add the local half of the security gate ([#68](https://github.com/acme/app/issues/68)) ([07d7745](https://github.com/acme/app/commit/07d7745af180c263b21035397240d152d39e1534))
* **tooling:** add the release-time security scanners ([#75](https://github.com/acme/app/issues/75)) ([07da9ca](https://github.com/acme/app/commit/07da9ca3c17856a4d0cf080da62965968cf739a1))
* **tooling:** make setup takes a blank machine to Android and iOS ready ([#70](https://github.com/acme/app/issues/70)) ([8ee5247](https://github.com/acme/app/commit/8ee5247178ea39359c565df9849ebfb273950b06))
* **ui:** monochrome skeleton theme and real tab bar icons ([#69](https://github.com/acme/app/issues/69)) ([88e335f](https://github.com/acme/app/commit/88e335f8f132c36eac8690496e6fa35fb50e5d10))

### Bug Fixes

* **release:** fail the gate when debug-signing finds a non-debug signer ([#72](https://github.com/acme/app/issues/72)) ([8e20f7b](https://github.com/acme/app/commit/8e20f7bd015782f9fb9ac877ef7c451d8722a19e))
* **release:** hand grep the C locale through env so bash cannot crash ([#71](https://github.com/acme/app/issues/71)) ([c9110a5](https://github.com/acme/app/commit/c9110a5101986ab4c9d5b060108c92a3b65215f3))
* **tooling:** group every make target into a prefix family ([#66](https://github.com/acme/app/issues/66)) ([5703c9b](https://github.com/acme/app/commit/5703c9bd525588a8af4d3a3a91a63bfeb7a8e7c4))
* **tooling:** keep Claude Code worktrees out of every tool's file walk ([#73](https://github.com/acme/app/issues/73)) ([e7875dc](https://github.com/acme/app/commit/e7875dcc1c28a321a01df1d50e8ca1c9338fc3d4))


<!-- workflows:append:Store notes -->
## Store notes

New
• Add the local half of the security gate.
• Add the release-time security scanners.
• Make setup takes a blank machine to Android and iOS ready.
• Monochrome skeleton theme and real tab bar icons.

Fixed
• Fail the gate when debug-signing finds a non-debug signer.
• Hand grep the C locale through env so bash cannot crash.
• Group every make target into a prefix family.
• Keep Claude Code worktrees out of every tool's file walk.
<!-- /workflows:append:Store notes -->

---
This PR was generated with [Release Please](https://github.com/googleapis/release-please). See [documentation](https://github.com/googleapis/release-please#release-please).

