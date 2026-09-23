#!/usr/bin/env bash
# Run the consumer's Playwright e2e script against the already-built,
# already-downloaded web export (build-web.yml's `playwright` job downloads the
# `build` job's dist/ before this runs).
#
# Contract: this always sets PLAYWRIGHT_SKIP_EXPORT=1 in the environment
# before invoking the consumer's E2E_SCRIPT (default test:e2e:web). A
# consumer whose e2e script re-exports the app before running Playwright
# (the template's test:e2e:web = `pnpm build:web --dev && playwright test`
# does, as of this writing) should check that variable and skip its own
# export step when it is set, since build-web.yml already exported and downloaded
# dist/ for it. The template does not honour it yet -- a follow-up task
# adapts it -- so today it re-exports redundantly but harmlessly; once
# updated this avoids a duplicate, slower export in CI.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd pnpm

: "${E2E_SCRIPT:?E2E_SCRIPT not set}"
export PLAYWRIGHT_SKIP_EXPORT="${PLAYWRIGHT_SKIP_EXPORT:-1}"

root="$(consumer_root)"
cd "$root"
pnpm run "$E2E_SCRIPT"
