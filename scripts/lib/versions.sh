#!/usr/bin/env bash
# Single source of pinned tool versions. Workflow defaults must match (scripts/self/check-versions.sh).
# shellcheck shell=bash
export MAESTRO_VERSION="2.10.0"
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
