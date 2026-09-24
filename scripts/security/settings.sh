#!/usr/bin/env bash
# Resolve the consumer's security policy once, for the whole workflow.
#
# A job-level `if:` cannot read a file, so check-security.yml cannot gate its
# scanner jobs on security-policy.json directly. This runs the consumer's own
# config.mjs - the same resolver `make check-security` uses, with the same
# environment-beats-file-beats-default order - and publishes the answer as step
# outputs that an `if:` can read.
#
# Shared carries no copy of that resolver. A consumer without one fails here,
# loudly, naming the file: two implementations of one resolution order drift,
# and the drifted one is always the one CI uses.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

root="$(consumer_root)"
cd "$root"

resolver='scripts/security/config.mjs'
[ -f "$resolver" ] || die_fix \
  "check-security.yml was called, but this repository has no $resolver" \
  "add scripts/security/ (config.mjs, the runners, verdict.mjs) as the template ships it, or stop calling check-security.yml" \
  "check-securityyml"

json="$(node "$resolver" --json)"
# An empty read is a real failure mode, not a hypothetical: config.mjs guards
# its command-line entry with `import.meta.main`, which is undefined before
# Node 24. An older node runs the file, defines its exports, prints nothing and
# exits 0. Reading that as "no jobs enabled" would switch the whole gate off in
# silence, which is the one outcome this gate must never produce.
[ -n "$json" ] || die "$resolver printed nothing. It needs Node 24 or newer (import.meta.main); this step runs after the setup action so the consumer's .mise.toml pin is what decides"

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
