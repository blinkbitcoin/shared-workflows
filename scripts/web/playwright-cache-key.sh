#!/usr/bin/env bash
# Wrap playwright-version.sh's plain stdout output as a `version` GITHUB_OUTPUT
# (mirrors scripts/ci/native-keys.sh wrapping native-hash.sh), so build-web.yml's
# playwright job can key its browser cache on it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

version=$(bash "$(dirname "$0")/playwright-version.sh" "$@")
gh_output version "$version"
