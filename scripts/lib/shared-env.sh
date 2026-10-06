#!/usr/bin/env bash
# The part of the env contract that scripts/lib/e2e-env.sh and
# scripts/lib/release-env.sh share: the one output directory a job stages
# everything in, the directory holding scripts/lib, and the platform check.
# Source it after common.sh; do not execute. Sourcing it creates nothing and
# publishes nothing: each env calls workflows_out_init once, when it is ready.
# shellcheck shell=bash

# Where everything this family produces in a job is staged. One default for
# both envs, so a job that runs E2E and release steps keeps one directory.
WORKFLOWS_OUT="${WORKFLOWS_OUT:-${RUNNER_TEMP:-/tmp}/workflows}"
export WORKFLOWS_OUT

# Directory holding scripts/lib, resolved from this file so callers in any
# subdirectory (scripts/native, scripts/e2e, scripts/release) find
# native-stack.sh beside it, even after they cd into the consumer.
WORKFLOWS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WORKFLOWS_LIB_DIR

# workflows_out_init - create $WORKFLOWS_OUT and publish it to $GITHUB_ENV, so
# every later step in the job (composite actions included) sees it without
# re-sourcing an env. gh_env_once's guard is file-based (it reads $GITHUB_ENV
# itself), so it dedupes across the many separate steps - each its own
# process - that source an env within one job, not just within one process.
workflows_out_init() {
  mkdir -p "$WORKFLOWS_OUT"
  gh_env_once WORKFLOWS_OUT "$WORKFLOWS_OUT"
}

# workflows_platform [ARG] -> ios|android. Positional argument wins over WORKFLOWS_PLATFORM.
workflows_platform() {
  local p="${1:-${WORKFLOWS_PLATFORM:-}}"
  case "$p" in
    ios | android) printf '%s\n' "$p" ;;
    *) die "platform must be ios or android (got '${p}'); pass it as \$1 or set WORKFLOWS_PLATFORM" ;;
  esac
}
