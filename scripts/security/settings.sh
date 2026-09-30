#!/usr/bin/env bash
# Resolve the consumer's security policy once, for the whole workflow.
#
# A job-level `if:` cannot read a file, so check-security.yml cannot gate its
# scanner jobs on security-settings.json directly. This runs the resolver
# (packages/app-tooling/lib/security-settings.mjs, the one `check-security`
# uses on a laptop, with the same environment-beats-file-beats-default order)
# over the consumer's security-settings.json, and publishes the answer as step
# outputs that an `if:` can read. A consumer with no settings file gets the
# defaults.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

# Resolved before the cd below: $0 may be a relative path.
resolver="$(cd "$(dirname "$0")/../../packages/app-tooling/lib" && pwd -P)/security-settings.mjs"
root="$(consumer_root)"
cd "$root"

json="$(node "$resolver" --json)"
# An empty read would switch the whole gate off in silence, which is the one
# outcome this gate must never produce: a resolver that printed nothing is a
# failure, never "no jobs enabled".
[ -n "$json" ] || die "$resolver printed nothing"

# shellcheck disable=SC2016  # process.env.* below is JS, not shell expansion
lines="$(SECURITY_SETTINGS_JSON="$json" node -e '
const settings = JSON.parse(process.env.SECURITY_SETTINGS_JSON);
const rows = [
  ["enabled", settings.enabled],
  ["severity", settings.severity],
  ["fail-on", settings.failOn.join(",")],
];
for (const [name, on] of Object.entries(settings.jobs)) rows.push([name, on]);
for (const [key, value] of rows) console.log(`${key}=${value}`);
')" || die "$resolver printed something that is not the settings object: $json"

while IFS='=' read -r key value; do
  [ -n "$key" ] || continue
  gh_output "$key" "$value"
  log "security: $key=$value"
done <<<"$lines"
