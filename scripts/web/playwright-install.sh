#!/usr/bin/env bash
# Install the Playwright browsers (plus their operating-system dependencies) the consumer's e2e
# suite needs. PLAYWRIGHT_BROWSERS is deliberately word-split below: it is a
# space-separated list of browser names (e.g. "chromium firefox"), the same
# way a shell caller would type them as separate playwright CLI arguments.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd pnpm

browsers="${PLAYWRIGHT_BROWSERS:-chromium}"
root="$(consumer_root)"
cd "$root"

# shellcheck disable=SC2086 # PLAYWRIGHT_BROWSERS is a space-separated name list, word-splitting is intended
pnpm exec playwright install $browsers --with-deps
