#!/usr/bin/env bash
# Publish the exported OTA update to a channel at a rollout percentage.
#
# Usage: publish.sh CHANNEL ROLLOUT
# Env: OTA_CLI_VERSION (required - the pinned eoas version), OTA_ENABLED,
#      OTA_PUBLISH_TOKEN.
#
# OTA_ENABLED is checked here as well as at the workflow level. The workflow
# guard (`if: inputs.ota-enabled`) is the one that normally applies; this one
# catches a hand-run of the script and a caller that wired the input to the
# wrong job.
#
# What is published is the export scripts/ota/export.sh produced in
# $WORKFLOWS_OTA_DIR - the bytes the fingerprint gate vetted, in that order. Letting
# the CLI export for itself would publish an artifact nothing in this pipeline
# ever looked at, built after the gate ran.
#
# FLAGS AND THE TOKEN NAME ARE UNVERIFIED OFFLINE: `--branch`,
# `--rollout-percentage`, `--non-interactive`, `--input-dir`/`--skip-bundler`
# and the EXPO_TOKEN environment variable are what the OTA runbook specifies for
# `eoas` (whose update command follows eas-cli's, where --input-dir only takes
# effect together with --skip-bundler), but no network was available to check
# them against the pinned OTA_CLI_VERSION. Confirm
# `npx eoas@$OTA_CLI_VERSION publish --help` when the version is first pinned in
# a real environment, and fix this call plus docs/consumer-guide.md together. A
# wrong token name fails as an auth error, not as a flag error.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
require_cmd npx

channel="${1:?usage: publish.sh CHANNEL ROLLOUT}"
rollout="${2:?usage: publish.sh CHANNEL ROLLOUT}"
require_env "OTA_CLI_VERSION:the pinned eoas version - never publish from an unpinned CLI"

if [ "${OTA_ENABLED:-false}" != "true" ]; then
  log "OTA_ENABLED is not 'true' - skipping publish to $channel"
  exit 0
fi

case "$rollout" in
  '' | *[!0-9]*) die "ROLLOUT must be an integer percentage 0-100 (got '$rollout')" ;;
esac
[ "$rollout" -ge 0 ] && [ "$rollout" -le 100 ] || die "ROLLOUT must be between 0 and 100 (got '$rollout')"

[ -d "$WORKFLOWS_OTA_DIR" ] && [ -n "$(ls -A "$WORKFLOWS_OTA_DIR" 2>/dev/null)" ] ||
  die "no export at $WORKFLOWS_OTA_DIR - run scripts/ota/export.sh first"

root="$(consumer_root)"
cd "$root"

# The token is exported under the name the CLI reads, not under the name the
# workflow passes it in as: OTA_PUBLISH_TOKEN is this family's contract, and
# mapping it here is what makes the workflow's `env:` entry actually do
# something. Unset means "whatever credentials the runner already has".
if [ -n "${OTA_PUBLISH_TOKEN:-}" ]; then
  export EXPO_TOKEN="$OTA_PUBLISH_TOKEN"
  log "publishing with the token from OTA_PUBLISH_TOKEN"
else
  log "OTA_PUBLISH_TOKEN is not set - publishing with whatever credentials the environment carries"
fi

group "ota publish ($channel @ ${rollout}%)"
npx "eoas@$OTA_CLI_VERSION" publish \
  --branch "$channel" \
  --rollout-percentage "$rollout" \
  --input-dir "$WORKFLOWS_OTA_DIR" \
  --skip-bundler \
  --non-interactive
endgroup
