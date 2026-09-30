#!/usr/bin/env bash
# knostic/OpenAnt (Apache-2.0) over the codebase: an LLM-driven scanner that
# detects candidate vulnerabilities, then checks each one's reachability from
# an entry point before reporting it. Off by default - it sends source to the
# configured provider and costs minutes and tokens - and in CI it runs on the
# release pull request only. Findings do not fail this script.
#
# The provider is the one the reviewer uses (llm.* in security-settings.json),
# written into a throwaway OpenAnt configuration for every one of its pipeline
# phases. Effort is not passed on: OpenAnt takes no effort setting.
#
# OpenAnt is a Go command-line tool over a Python core, pinned by commit below.
# Locally, install it yourself and put `openant` on PATH; under CI a missing
# binary is built from that commit into $OPENANT_HOME.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

# knostic/OpenAnt master on 2026-09-24. Moving it is a reviewed change: the
# workflow's build cache is keyed on this file.
OPENANT_REPOSITORY=https://github.com/knostic/OpenAnt
OPENANT_COMMIT=624068274c52e53578d89d403b29cf73665720bf
GO_VERSION=1.26

sec_enabled review-codebase

provider="$(sec_setting llm.provider)"
model="$(sec_setting llm.model)"
case "$provider" in
  openai) key_name=OPENAI_API_KEY ;;
  anthropic) key_name=ANTHROPIC_API_KEY ;;
  *)
    sec_skip review-codebase "no LLM provider configured (llm.provider or SECURITY_LLM_PROVIDER)"
    exit 0
    ;;
esac
[ -n "${!key_name:-}" ] || {
  sec_skip review-codebase "$key_name is not set"
  exit 0
}
[ -n "$model" ] || {
  sec_skip review-codebase "no model configured (llm.model or SECURITY_LLM_MODEL): OpenAnt has no default for a non-Anthropic provider"
  exit 0
}

if ! command -v openant >/dev/null 2>&1; then
  if [ -z "${CI:-}" ]; then
    sec_skip review-codebase "openant is not installed ($OPENANT_REPOSITORY, apps/openant-cli: make build)"
    exit 0
  fi
  home="${OPENANT_HOME:-$HOME/.cache/openant}/$OPENANT_COMMIT"
  if [ ! -x "$home/apps/openant-cli/bin/openant" ]; then
    rm -rf "$home"
    git init -q "$home"
    git -C "$home" fetch -q --depth 1 "$OPENANT_REPOSITORY" "$OPENANT_COMMIT"
    git -C "$home" checkout -q FETCH_HEAD
    (cd "$home/apps/openant-cli" && mise x "go@$GO_VERSION" -- go build -o bin/openant ./main.go)
  fi
  export OPENANT_CORE_PATH="$home/libs/openant-core"
  PATH="$home/apps/openant-cli/bin:$PATH"
fi

out="$(cd "$(sec_out_dir)" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The configuration carries the key, so it lives in a private directory that
# the trap removes, is written by node (never echoed through the shell) and is
# readable by this user alone.
export XDG_CONFIG_HOME="$work/config"
mkdir -p "$XDG_CONFIG_HOME/openant"
(
  umask 077
  # shellcheck disable=SC2016 # the single quotes hold JavaScript, not shell
  OPENANT_PROVIDER="$provider" OPENANT_MODEL="$model" OPENANT_KEY_NAME="$key_name" node -e '
const { env } = process;
const provider = { type: env.OPENANT_PROVIDER, api_key: env[env.OPENANT_KEY_NAME] };
if (env.OPENANT_PROVIDER === "openai" && env.OPENAI_BASE_URL) provider.base_url = env.OPENAI_BASE_URL;
const phase = { provider: "security", model: env.OPENANT_MODEL };
const phases = ["app_context", "llm_reach", "enhance", "analyze", "verify", "dynamic_test", "report"];
process.stdout.write(JSON.stringify({
  $schema_version: 2,
  default_llm: "security",
  llm_providers: { security: provider },
  llm_configs: { security: Object.fromEntries(phases.map((name) => [name, phase])) },
}));
' > "$XDG_CONFIG_HOME/openant/config.json"
)

limit="$(sec_setting options.review-codebase.limit)"
verify="$(sec_setting options.review-codebase.verify)"
args=(scan . -l javascript -o "$work/scan" --llm-config security --skip-dynamic-test --no-report)
[ "$limit" = 0 ] || args+=(--limit "$limit")
[ "$verify" != true ] || args+=(--verify)

# OpenAnt's contract: 0 clean, 1 vulnerabilities found (a successful run),
# 2 or more a failed scan.
status=0
openant "${args[@]}" > "$work/scan.log" 2>&1 || status=$?
if [ "$status" -gt 1 ]; then
  cat "$work/scan.log" >&2
  echo "openant scan failed (exit $status)" >&2
  exit 1
fi

# `|| true`: a scan that wrote nothing leaves no directory to search, and find
# failing under pipefail would end the script before the skip below.
results="$(find "$work/scan" -name results_verified.json 2>/dev/null | head -1 || true)"
[ -n "$results" ] || results="$(find "$work/scan" -name results.json 2>/dev/null | head -1 || true)"
if [ -z "$results" ]; then
  sec_skip review-codebase "OpenAnt finished (exit $status) without a results file: nothing reachable to analyse"
  exit 0
fi
openant report "$results" -f sarif -o "$out/review-codebase.sarif" > "$work/report.log" 2>&1 || {
  cat "$work/report.log" >&2
  echo "openant report failed to write SARIF" >&2
  exit 1
}
echo "review-codebase: wrote $out/review-codebase.sarif"
