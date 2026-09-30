#!/usr/bin/env bash
# The CI check: lint a consumer's own shell scripts and .github/workflows/, and
# audit .github/ for workflow security, with the same pinned shellcheck,
# actionlint and zizmor versions this repository's own `make check-ci` uses.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/versions.sh"

root="$(consumer_root)"
cd "$root"

# WORKFLOWS_SHELLCHECK_PATHS: the directories to lint, space-separated
# (default scripts). A directory that does not exist is skipped.
# shellcheck disable=SC2206 # an intentionally space-separated list of directories
shellcheck_paths=(${WORKFLOWS_SHELLCHECK_PATHS:-scripts})
existing=()
for dir in "${shellcheck_paths[@]}"; do
  if [ -d "$dir" ]; then existing+=("$dir"); fi
done

if [ "${#existing[@]}" -eq 0 ] && [ ! -d .github/workflows ]; then
  log "check-ci: no ${shellcheck_paths[*]} and no .github/workflows/ in $root; nothing to lint"
  exit 0
fi

require_cmd mise

# One gate, the three linters of the CI code (check.yml's `ci` input turns it
# on or off as a whole). Each half is guarded on what it reads: a consumer with
# workflows but no scripts/ directory (a perfectly normal Expo app) must still
# get actionlint and zizmor.
if [ -d .github/workflows ]; then
  mise x "actionlint@$ACTIONLINT_VERSION" -- actionlint -color
else
  log "check-ci: skipping actionlint"
fi

# zizmor is the security half of the workflow lint: template injection, broad
# permissions, App tokens with blanket scope, dangerous triggers - none of which
# actionlint looks at. --offline keeps it deterministic: the online audits ask
# the GitHub API, and a gate must not change its answer with the network.
# A consumer's own zizmor.yml (.github/ first, then the repository root, the
# order zizmor itself searches) is its policy; without one it gets this
# family's, which allows tag pins (see .github/zizmor.yml here). The file is
# always passed with --config rather than left to zizmor's discovery: that
# stops at the nearest `.git` *directory*, and a worktree's `.git` is a file,
# so a run from a worktree nested in another checkout would read that
# checkout's policy instead.
if [ -d .github/workflows ]; then
  if [ -f .github/zizmor.yml ]; then
    config=.github/zizmor.yml
  elif [ -f zizmor.yml ]; then
    config=zizmor.yml
  elif [ -f "$(dirname "$0")/../../.github/zizmor.yml" ]; then
    # Run from this repository: its own policy.
    config="$(cd "$(dirname "$0")/../.." && pwd)/.github/zizmor.yml"
  else
    # Run from the app-tooling package, which carries the same policy at its root.
    config="$(cd "$(dirname "$0")/.." && pwd)/zizmor.yml"
  fi
  mise x "zizmor@$ZIZMOR_VERSION" -- zizmor --offline --min-severity medium --config "$config" .github
else
  log "check-ci: skipping zizmor"
fi

if [ "${#existing[@]}" -gt 0 ]; then
  files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "${existing[@]}" -name '*.sh')
  if [ "${#files[@]}" -gt 0 ]; then
    mise x "shellcheck@$SHELLCHECK_VERSION" -- shellcheck -x "${files[@]}"
  fi
else
  log "check-ci: skipping shellcheck"
fi
