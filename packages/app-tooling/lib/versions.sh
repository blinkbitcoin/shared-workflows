#!/usr/bin/env bash
# Single source of pinned tool versions. Workflow defaults must match (scripts/self/check-version-pins.sh).
# shellcheck shell=bash
export MAESTRO_VERSION="2.10.0"
# SHA-256 of that release's maestro.zip (github.com/mobile-dev-inc/maestro,
# tag cli-2.10.0): scripts/ci/maestro-install.sh refuses any other bytes. The
# same value the consumer template's laptop installer checks.
export MAESTRO_SHA256="29b675e10cc12080e445e9bfb2e2b4e4dfb9c0f2e30d5884120d258b5e1cd991"
export ANDROID_API_LEVEL="34"
export ACTIONLINT_VERSION="1.7.12"
export SHELLCHECK_VERSION="0.11.0"
export YQ_VERSION="4.53.6"
export TYPOS_VERSION="1.50.1"
export LEFTHOOK_VERSION="2.1.14"
export ZIZMOR_VERSION="1.30.1"
export GITLEAKS_VERSION="8.30.1"
# bundletool derives the universal APK from the .aab in the android build lane;
# no runner image ships it, so scripts/ci/bundletool-install.sh downloads this
# exact release.
export BUNDLETOOL_VERSION="1.17.2"
