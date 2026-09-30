#!/usr/bin/env bash
# Re-extract i18n strings and fail if that produced any uncommitted diff, i.e.
# the checked-in locale files are stale relative to the source strings.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/git-clean.sh"
require_cmd git

root="$(consumer_root)"
# shellcheck disable=SC2206 # I18N_PATHS is an intentionally space-separated list of pathspecs
paths=(${I18N_PATHS:-src/i18n/locales})

bash "$(dirname "$0")/run-script.sh" i18n:extract

cd "$root"
assert_clean_paths "${paths[@]}" ||
  die "i18n:extract produced uncommitted or untracked changes in: ${paths[*]} (run \"pnpm run i18n:extract\" and commit the result)"
