#!/usr/bin/env bash
# Regenerate GraphQL codegen output and fail if that produced any uncommitted
# diff, i.e. the checked-in generated code is stale relative to the schema.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/git-clean.sh"
require_cmd git

root="$(consumer_root)"
# shellcheck disable=SC2206 # CODEGEN_PATHS is an intentionally space-separated list of pathspecs
paths=(${CODEGEN_PATHS:-src/graphql/generated})

bash "$(dirname "$0")/run-script.sh" codegen

cd "$root"
assert_clean_paths "${paths[@]}" ||
  die "codegen produced uncommitted or untracked changes in: ${paths[*]} (run \"pnpm run codegen\" and commit the result)"
