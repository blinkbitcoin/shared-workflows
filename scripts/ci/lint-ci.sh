#!/usr/bin/env bash
# Lint a consumer's own scripts/ and .github/workflows/ with the same pinned
# actionlint/shellcheck versions this repo's own `make check` uses.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/versions.sh"

root="$(consumer_root)"
cd "$root"

if [ ! -d scripts ] && [ ! -d .github/workflows ]; then
  log "lint-ci: no scripts/ and no .github/workflows/ in $root; nothing to lint"
  exit 0
fi

require_cmd mise

# WORKFLOWS_ACTIONLINT / WORKFLOWS_SHELLCHECK let a single invocation toggle either half
# independently (check-code.yml's `actionlint` and `shellcheck` inputs), while
# `make check` (no env set) still runs both. The two halves are guarded
# separately on purpose: a consumer with workflows but no scripts/ directory (a
# perfectly normal Expo app) must still get actionlint.
if [ "${WORKFLOWS_ACTIONLINT:-true}" = "true" ] && [ -d .github/workflows ]; then
  mise x "actionlint@$ACTIONLINT_VERSION" -- actionlint -color
else
  log "lint-ci: skipping actionlint"
fi

# zizmor is the security half of the workflow lint: template injection, broad
# permissions, App tokens with blanket scope, dangerous triggers - none of which
# actionlint looks at. --offline keeps it deterministic: the online audits ask
# the GitHub API, and a gate must not change its answer with the network.
# A consumer's own zizmor.yml (repo root or .github/) is its policy; without one
# it gets this family's, which allows tag pins (see .github/zizmor.yml here).
if [ "${WORKFLOWS_ZIZMOR:-true}" = "true" ] && [ -d .github/workflows ]; then
  config=()
  if [ ! -f zizmor.yml ] && [ ! -f .github/zizmor.yml ]; then
    config=(--config "$(cd "$(dirname "$0")/../.." && pwd)/.github/zizmor.yml")
  fi
  mise x "zizmor@$ZIZMOR_VERSION" -- zizmor --offline --min-severity medium ${config[@]+"${config[@]}"} .github
else
  log "lint-ci: skipping zizmor"
fi

if [ "${WORKFLOWS_SHELLCHECK:-true}" = "true" ] && [ -d scripts ]; then
  files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find scripts -name '*.sh')
  if [ "${#files[@]}" -gt 0 ]; then
    mise x "shellcheck@$SHELLCHECK_VERSION" -- shellcheck -x "${files[@]}"
  fi
else
  log "lint-ci: skipping shellcheck"
fi
