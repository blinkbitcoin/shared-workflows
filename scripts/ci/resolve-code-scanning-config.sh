#!/usr/bin/env bash
# Write the CodeQL configuration check-code-scanning.yml hands to
# codeql-action/init: the family's defaults with the consumer's own file merged
# over them. resolve-code-scanning-config.mjs does the merge; this finds it from
# the shared-workflows checkout this script sits in, so the workflow has one
# bash line to call.
#
#   resolve-code-scanning-config.sh <consumer config file> <output file>
#
# Run from the consumer's root. The config file need not exist.
set -euo pipefail
[ $# -eq 2 ] || {
  echo "usage: resolve-code-scanning-config.sh <consumer config file> <output file>" >&2
  exit 2
}
here="$(cd "$(dirname "$0")" && pwd -P)"
exec node "$here/../../packages/app-tooling/bin/resolve-code-scanning-config.mjs" --config "$1" --out "$2"
