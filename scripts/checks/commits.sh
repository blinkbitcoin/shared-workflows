#!/usr/bin/env bash
# Lint $PR_TITLE (a GitHub Actions expression, e.g. github.event.pull_request.title)
# against Conventional Commits. PR_TITLE is attacker-influenced (any contributor
# can set a PR title) so it is only ever read from the environment and piped to
# commitlint's stdin -- never interpolated into a command line or shell string.
#
# Optionally, PR_COMMITS_RANGE="<base-sha>..<head-sha>" (also attacker-influenced
# only via shas, never free text) also lints every commit in that range -- for
# consumers that want each commit conventional, not just the squashed PR title.
# The checkout that sets this must use fetch-depth: 0 so both shas are present.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

title="${PR_TITLE:?PR_TITLE not set}"
range="${PR_COMMITS_RANGE:-}"
root="$(consumer_root)"

has_commitlint_dep() {
  [ -f "$root/package.json" ] || return 1
  PKG_PATH="$root/package.json" node -e \
    "process.exit(require(process.env.PKG_PATH).devDependencies?.['@commitlint/cli'] ? 0 : 1)" \
    2>/dev/null
}

run_range_lint() {
  local from="${range%%..*}" to="${range##*..}" runner=("$@")
  [ -n "$range" ] || return 0
  [ -n "$from" ] && [ -n "$to" ] || die "PR_COMMITS_RANGE must be \"<base-sha>..<head-sha>\", got: $range"
  "${runner[@]}" --from "$from" --to "$to"
}

if has_commitlint_dep; then
  require_cmd pnpm
  cd "$root"
  printf '%s\n' "$title" | pnpm exec commitlint
  run_range_lint pnpm exec commitlint
else
  require_cmd npx
  tmp="${RUNNER_TEMP:-/tmp}"
  config="$tmp/commitlint.config.mjs"
  cat > "$config" <<'EOF'
export default { extends: ["@commitlint/config-conventional"] };
EOF
  # npx's single-package positional form only installs the first package and
  # passes the rest as CLI args to it, so config-conventional never resolves;
  # -p/--package must be repeated to install both (verified against npx 11.x).
  printf '%s\n' "$title" |
    npx --yes -p @commitlint/cli@21 -p @commitlint/config-conventional@21 \
      commitlint --config "$config"
  run_range_lint npx --yes -p @commitlint/cli@21 -p @commitlint/config-conventional@21 \
    commitlint --config "$config"
fi
