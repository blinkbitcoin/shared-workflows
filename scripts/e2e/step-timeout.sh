#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# GitHub Actions expressions have no arithmetic operators, so `timeout-minutes:
# ${{ inputs.suite-timeout-minutes + 5 }}` cannot be written inline. This step
# computes the per-attempt suite bound plus a margin (device teardown, forensics)
# and publishes it as the `minutes` output.
# An empty value (the workflow passes an input through even when the caller
# left it empty) takes the default before the integer check sees it.
WORKFLOWS_SUITE_TIMEOUT_MINUTES="${WORKFLOWS_SUITE_TIMEOUT_MINUTES:-10}"
WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES="${WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES:-5}"
require_uint WORKFLOWS_SUITE_TIMEOUT_MINUTES WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES

gh_output minutes "$((WORKFLOWS_SUITE_TIMEOUT_MINUTES + WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES))"
