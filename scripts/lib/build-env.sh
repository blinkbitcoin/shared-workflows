#!/usr/bin/env bash
# Publish the caller's non-secret build environment ($WORKFLOWS_BUILD_ENV, a flat JSON
# object) into $GITHUB_ENV, so values like OTA_ENABLED, EXPO_UPDATES_URL,
# EXPO_PUBLIC_*, ANDROID_UPLOAD_CERT_SHA256 or STORE_NOTES_INCLUDE_CHANGELOG
# reach prebuild, the fastlane lanes, the verify scripts and the notes generator.
#
# Only key names are logged, never values - the keys are what a reader needs in
# order to debug "why did this build get that flag", and a value that turned out
# to be sensitive should not be in the log because it was assumed not to be.
#
# Keys must match ^[A-Z][A-Z0-9_]*$, and a key that *looks* like a credential
# (ends in _KEY, _TOKEN, _PASSWORD, _SECRET, or is a known credential name) is
# refused outright. This input is a workflow `inputs:` value: GitHub does not
# mask it, it shows in the run's parameters, and it is trivially readable by
# anyone who can see the run. Refusing here is the difference between a caller
# noticing at once and a credential quietly ending up in a public log.
#
# A key that belongs to this workflow family (WORKFLOWS_*) or to the runner itself
# (GITHUB_*, RUNNER_*, ACTIONS_*, PATH, HOME, LD_*, DYLD_*, NODE_OPTIONS) is
# refused for a different reason: build-env is published before fingerprint.sh
# runs, so `{"WORKFLOWS_FINGERPRINT_IOS":"<baseline>"}` would hand the OTA fingerprint gate a
# caller-supplied constant to compare its baseline against, and WORKFLOWS_ASSETS_DIR /
# WORKFLOWS_RELEASE_META_DIR would repoint the artifact paths mid-job.
#
# Values may contain anything, including newlines: they go into $GITHUB_ENV
# through gh_env, which switches to the heredoc form rather than emitting a
# second `KEY=` line the runner would read as another variable.
#
# Usage: source it, then workflows_publish_build_env
# shellcheck shell=bash

workflows_publish_build_env() {
  local json count
  json="${WORKFLOWS_BUILD_ENV:-}"
  if [ -z "$json" ] || [ "$json" = '{}' ]; then
    log "build-env is empty - nothing to publish"
    return 0
  fi
  require_cmd node

  local env_file="${RUNNER_TEMP:-/tmp}/workflows-build-env.env"
  # `if !`, not a bare call: the scratch file must not survive a rejection
  # either, and errexit would abort before any cleanup could run.
  #
  # The rules live in packages/app-tooling/lib/env-validate.mjs, shared with
  # scripts/release/env-json.sh so the two inputs cannot be validated differently
  # - which is exactly what had happened.
  local validator
  validator="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../packages/app-tooling/lib" && pwd)/env-validate.mjs"
  if ! WORKFLOWS_ENV_VALIDATE_JSON="$json" \
    WORKFLOWS_ENV_VALIDATE_LABEL=build-env \
    node "$validator" > "$env_file"; then
    rm -f "$env_file"
    exit 1
  fi

  count=0
  local key value
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    log "build-env: $key"
    gh_env "$key" "$value"
    count=$((count + 1))
  done < "$env_file"
  rm -f "$env_file"
  log "build-env: published $count variable(s)"
}
