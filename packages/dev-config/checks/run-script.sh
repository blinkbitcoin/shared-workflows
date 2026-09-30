#!/usr/bin/env bash
# Run a named consumer package.json script; fall back to a same-named
# node_modules/.bin binary for tools the template doesn't wrap in a script
# (e.g. knip). This is the contract every other check wrapper builds on.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node pnpm

name="${1:?usage: run-script.sh NAME}"
root="$(consumer_root)"
cd "$root"

has_script() {
  RUN_SCRIPT_NAME="$name" node -e \
    "process.exit(require('./package.json').scripts?.[process.env.RUN_SCRIPT_NAME] ? 0 : 1)" \
    2>/dev/null
}

if has_script; then
  exec pnpm run "$name"
elif [ -x "node_modules/.bin/$name" ]; then
  exec pnpm exec "$name"
else
  die_fix \
    "consumer package.json has no \"$name\" script, and no $name binary in node_modules/.bin" \
    "add a \"$name\" script, or switch the gate that calls it off in your caller - run check-consumer-contract for which input that is, and for everything else this repository is missing" \
    "script-contract"
fi
