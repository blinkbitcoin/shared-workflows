#!/usr/bin/env bash
# Export the consumer's web build via its own package.json script (default
# build:web = `expo export --platform web`), then assert the output actually
# landed. EXPORT_ARGS is deliberately word-split below: it carries
# space-separated flags (e.g. "--dev") straight through to the consumer
# script, the same way a shell caller would type them.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd pnpm

require_env EXPORT_SCRIPT OUTPUT_DIR
args="${EXPORT_ARGS:-}"

root="$(consumer_root)"
cd "$root"

group "Export the web build ($EXPORT_SCRIPT)"
# shellcheck disable=SC2086 # EXPORT_ARGS is a space-separated flag list, word-splitting is intended
pnpm run "$EXPORT_SCRIPT" -- $args
endgroup

[ -f "$OUTPUT_DIR/index.html" ] || die "web export did not produce $OUTPUT_DIR/index.html (script: $EXPORT_SCRIPT)"
