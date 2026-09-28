#!/usr/bin/env bash
# Run the consumer's Playwright e2e script against the already-built,
# already-downloaded web export (build-web.yml's `playwright` job downloads the
# `build` job's dist/ before this runs).
#
# Contract: this always sets PLAYWRIGHT_SKIP_EXPORT=1 in the environment
# before invoking the consumer's E2E_SCRIPT (default test:e2e:web). A
# consumer whose e2e script exports the app before running Playwright should
# check that variable and skip its own export when it is set: build-web.yml
# already exported and downloaded dist/, and those are the bytes a deploy would
# publish. The template's test:e2e:web (scripts/e2e/web.sh) does exactly that;
# the consumer guide's "The Playwright / export contract" shows the shape.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd pnpm

: "${E2E_SCRIPT:?E2E_SCRIPT not set}"
export PLAYWRIGHT_SKIP_EXPORT="${PLAYWRIGHT_SKIP_EXPORT:-1}"

root="$(consumer_root)"
cd "$root"
pnpm run "$E2E_SCRIPT"
