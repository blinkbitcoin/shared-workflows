#!/usr/bin/env bash
# Publish the flat JSON object in $WORKFLOWS_ENV_JSON into $GITHUB_ENV so a fastlane
# lane can read caller-supplied values it was not designed to take as
# arguments (APP_VARIANT, a store track name, ...).
#
# Values are printed, so this is for configuration, never for credentials - a
# secret belongs in `secrets:` and decode-secrets.sh.
#
# Key policy is not merely mirrored from scripts/lib/build-env.sh, it is the same
# code: both call packages/app-tooling/lib/env-validate.mjs. The previous header claimed the
# two could not drift because the same assertions covered both. They had already
# drifted - this script had no credential-name refusal and no NEVER list, so a
# key like SENTRY_AUTH_TOKEN was published from an unmasked workflow input - and
# a claim of that kind is worth no more than the mechanism behind it.
#
# A name owned by this family or by the runner is refused too, because
# build-env's fingerprint-override hole is reachable through this input as well.
# Values reach $GITHUB_ENV through gh_env, which uses the heredoc form for a
# value containing a newline rather than writing a second `KEY=` line the
# runner would read as another variable.
#
# Usage: env-json.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

env_file="${RUNNER_TEMP:-/tmp}/workflows-env-json.env"
trap 'rm -f "$env_file"' EXIT

json="${WORKFLOWS_ENV_JSON:-}"
if [ -z "$json" ] || [ "$json" = '{}' ]; then
  log "WORKFLOWS_ENV_JSON is empty - nothing to publish"
  exit 0
fi
require_cmd node

# node, not yq: only node can reliably reject a non-object and coerce scalars to
# the exact strings GitHub's env file expects.
#
# The rules live in packages/app-tooling/lib/env-validate.mjs, shared with build-env.sh. They
# used to be a copy here, and the copy had drifted where it mattered most: no
# credential-name refusal at all, so {"SENTRY_AUTH_TOKEN": "..."} was published
# from an input GitHub does not mask.
# ALLOW_LOWERCASE: these keys reach a fastlane lane, and fastlane's own option
# names (`track`, `lane`) are lower-case. That difference from build-env is
# documented in docs/consumer-guide.md and is the only one; the credential,
# reserved-name and scalar rules are identical, and the validator upper-cases
# each key before applying them so a lower-case name cannot dodge them.
WORKFLOWS_ENV_VALIDATE_JSON="$json" \
  WORKFLOWS_ENV_VALIDATE_LABEL=WORKFLOWS_ENV_JSON \
  WORKFLOWS_ENV_VALIDATE_ALLOW_LOWERCASE=1 \
  node "$(dirname "$0")/../../packages/app-tooling/lib/env-validate.mjs" > "$env_file"

while IFS= read -r -d '' key && IFS= read -r -d '' value; do
  log "env-json: $key"
  gh_env "$key" "$value"
done < "$env_file"
