#!/usr/bin/env bash
# Assert the five Fastfile contract variables are present and non-empty, at the
# start of a lane workflow rather than inside the lane.
#
# Why this exists. The three lane workflows declare all five as `required: true`
# inputs, and that is weaker than it reads: a caller passes them as
# `${{ vars.IOS_BUNDLE_ID }}`, an unset repository variable interpolates to the
# empty string, and an empty string satisfies `required`. The only thing in the
# family that rejects an empty value is the consumer's own Fastfile, in
# `before_all`.
#
# That leaves two gaps. A consumer that did not copy that `before_all` - anyone
# adopting these workflows into an existing app - has no check at all, and an
# empty identifier flows into the lane. And a consumer that did copy it only
# finds out after prebuild and pod install, which on the iOS lane means several
# minutes of a runner that bills at ten times the Linux rate.
#
# So the same assertion moves to the front, where it costs nothing, and names
# the repository variable to set rather than the environment variable it became.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

missing=()
for name in APP_VERSION APP_BUILD_NUMBER IOS_BUNDLE_ID IOS_SCHEME ANDROID_PACKAGE; do
  # Empty after trimming, not just unset: `vars.X` for an unset X is "".
  value="$(printf '%s' "${!name:-}" | tr -d '[:space:]')"
  [ -n "$value" ] || missing+=("$name")
done

if [ "${#missing[@]}" -gt 0 ]; then
  die_fix \
    "these lane inputs are empty: ${missing[*]} - every lane on both platforms asserts all five in before_all, whichever platform it builds" \
    "APP_VERSION and APP_BUILD_NUMBER come from build-prepare's outputs; IOS_BUNDLE_ID, IOS_SCHEME and ANDROID_PACKAGE come from repository variables of the same name. An unset repository variable is the empty string, and an empty string satisfies a required: true input - which is why this is checked here rather than trusted" \
    "the-five-fastfile-contract-variables"
fi

log "lane inputs: all five contract variables are set"
