#!/usr/bin/env bash
# The generated-file drift gate: regenerate what the consumer's generators write
# - gen:i18n (the translation catalogs) and gen:graphql (the typed GraphQL
# documents), whichever of the two it has - and fail when that left a modified
# or untracked file, i.e. the checked-in output is stale against its sources.
#
# I18N_PATHS and GRAPHQL_PATHS: the space-separated pathspecs each generator
# writes (defaults src/i18n/locales and src/graphql/generated). A consumer with
# neither generator has nothing to check and is told to switch the gate off.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/git-clean.sh"
require_cmd git node

root="$(consumer_root)"

has_script() {
  (cd "$root" && RUN_SCRIPT_NAME="$1" node -e \
    "process.exit(require('./package.json').scripts?.[process.env.RUN_SCRIPT_NAME] ? 0 : 1)" \
    2>/dev/null)
}

ran=0
# check SCRIPT PATH... - run SCRIPT, then fail on any drift under the paths.
check() {
  local script="$1"
  shift
  if ! has_script "$script"; then
    log "generated: no \"$script\" script, so nothing of it to check"
    return 0
  fi
  bash "$(dirname "$0")/run-script.sh" "$script"
  (cd "$root" && assert_clean_paths "$@") ||
    die "$script produced uncommitted or untracked changes in: $* (run \"pnpm run $script\" and commit the result)"
  ran=$((ran + 1))
}

# shellcheck disable=SC2206 # I18N_PATHS is an intentionally space-separated list of pathspecs
i18n_paths=(${I18N_PATHS:-src/i18n/locales})
# shellcheck disable=SC2206 # GRAPHQL_PATHS is an intentionally space-separated list of pathspecs
graphql_paths=(${GRAPHQL_PATHS:-src/graphql/generated})
check gen:i18n "${i18n_paths[@]}"
check gen:graphql "${graphql_paths[@]}"

[ "$ran" -gt 0 ] ||
  die "generated: the consumer has neither a \"gen:i18n\" nor a \"gen:graphql\" script, so there is nothing generated to check - add one, or pass generated: false in your caller"
