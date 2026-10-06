#!/usr/bin/env bash
# Sourced by ios-maestro.sh and android-maestro.sh, after lib/common.sh and
# lib/e2e-env.sh: the Maestro suite run both platforms share. Each platform script keeps
# only what is its own (the device it addresses, the emulator, the recording,
# the launch, its EXIT trap) around two calls:
#
#   prepare_maestro_suite
#     export MAESTRO_DRIVER_STARTUP_TIMEOUT, cd into the consumer, and check
#     the flows directory and create the output directory; exits on failure.
#   run_maestro_suite PLATFORM DISPLAY_NAME [DEVICE_ARGUMENT...] -- [MAESTRO_TEST_ARGUMENT...]
#     run `maestro test` on PLATFORM (ios or android, passed to --platform and
#     to workflows_app_id), bounded by WORKFLOWS_SUITE_TIMEOUT_MINUTES,
#     rerun once unless it hung (124), and returns the suite's status; a green
#     suite whose junit report shows no flows exits through
#     workflows_assert_suite_ran. DISPLAY_NAME (iOS, Android) names the log
#     groups and the report check. Device arguments follow --platform (iOS
#     passes --udid); the Maestro test arguments after `--` go last, so a
#     caller can narrow or extend one local run.
#
# Output: $WORKFLOWS_OUT/maestro/junit.xml + debug output (screenshots, per-flow logs).
# shellcheck shell=bash

# shellcheck source=scripts/e2e/maestro-bound.sh
. "$(dirname "${BASH_SOURCE[0]}")/maestro-bound.sh"

prepare_maestro_suite() {
  # The driver installs and launches its runner on first use, minutes on a cold
  # device; the value must stay below the suite bound (see the helper) so a
  # runner that fails to launch is retried instead of burning the bound.
  export MAESTRO_DRIVER_STARTUP_TIMEOUT
  MAESTRO_DRIVER_STARTUP_TIMEOUT="$(workflows_driver_startup_timeout 300000)" || exit 1

  local root
  root="$(consumer_root)"
  cd "$root" || exit 1
  [ -d "$WORKFLOWS_MAESTRO_FLOWS" ] || die "no flows directory at $root/$WORKFLOWS_MAESTRO_FLOWS (WORKFLOWS_MAESTRO_FLOWS)"
  mkdir -p "$WORKFLOWS_OUT/maestro"
}

run_maestro_suite() {
  local usage="usage: run_maestro_suite PLATFORM DISPLAY_NAME [DEVICE_ARGUMENT...] -- [MAESTRO_TEST_ARGUMENT...]"
  [ "$#" -ge 2 ] || die "$usage"
  local platform="$1" display_name="$2"
  shift 2
  local device_arguments=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    device_arguments+=("$1")
    shift
  done
  [ "$#" -gt 0 ] || die "run_maestro_suite: no -- before the Maestro test arguments ($usage)"
  shift

  local flows="$WORKFLOWS_MAESTRO_FLOWS" out="$WORKFLOWS_OUT/maestro"
  # --platform so a device of the other platform on the same machine is never
  # picked. The `+` form: bash 3.2 (macOS's /bin/bash) calls an empty array
  # unbound under `set -u`.
  local args=(test "$flows" --platform "$platform" ${device_arguments[@]+"${device_arguments[@]}"})
  [ -f "$flows/config.yaml" ] && args+=(--config "$flows/config.yaml")
  args+=(
    -e "APP_ID=$(workflows_app_id "$platform")"
    --debug-output "$out"
    --flatten-debug-output
    --format junit
    --output "$out/junit.xml"
  )
  # The consumer's config.yaml usually carries includeTags already; the env var is
  # for narrowing a single run (a smoke-only PR job) without editing the config.
  [ -n "${WORKFLOWS_MAESTRO_INCLUDE_TAGS:-}" ] && args+=(--include-tags "$WORKFLOWS_MAESTRO_INCLUDE_TAGS")
  [ -n "${WORKFLOWS_MAESTRO_EXCLUDE_TAGS:-}" ] && args+=(--exclude-tags "$WORKFLOWS_MAESTRO_EXCLUDE_TAGS")
  # Whatever the caller passes goes last, so a developer can narrow or extend one
  # local run without an environment variable for every Maestro flag.
  args+=("$@")

  local bound=$((WORKFLOWS_SUITE_TIMEOUT_MINUTES * 60)) status=0
  group "maestro test ($display_name, bound ${WORKFLOWS_SUITE_TIMEOUT_MINUTES}m)"
  bounded_maestro "$bound" maestro "${args[@]}" || status=$?
  endgroup

  # A hung driver is not retried - the second attempt would only run into the
  # step's timeout-minutes and cost another suite's worth of wall clock.
  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
    log "::warning::Maestro suite failed (status $status) - rerunning the suite once"
    status=0
    group "maestro test ($display_name, retry)"
    bounded_maestro "$bound" maestro "${args[@]}" || status=$?
    endgroup
  fi
  # A green suite still has to have been a suite. Maestro exits 0 when its flow
  # selection matches nothing, so success is only success once the junit report
  # says how many flows actually ran.
  if [ "$status" -eq 0 ]; then
    workflows_assert_suite_ran "$out/junit.xml" "$display_name"
  fi
  return "$status"
}
