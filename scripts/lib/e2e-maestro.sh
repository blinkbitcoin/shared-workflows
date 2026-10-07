#!/usr/bin/env bash
# Maestro policy for E2E: where the flows live, how long a suite may run, the
# driver-startup timeout that must stay below that bound, and the check that a
# suite ran at all. Part of the env contract scripts/lib/e2e-env.sh
# assembles; source that, after common.sh.
# shellcheck shell=bash

WORKFLOWS_MAESTRO_FLOWS="${WORKFLOWS_MAESTRO_FLOWS:-.maestro}"
WORKFLOWS_SUITE_TIMEOUT_MINUTES="${WORKFLOWS_SUITE_TIMEOUT_MINUTES:-10}"
export WORKFLOWS_MAESTRO_FLOWS WORKFLOWS_SUITE_TIMEOUT_MINUTES

# workflows_driver_startup_timeout DEFAULT_MS -> the MAESTRO_DRIVER_STARTUP_TIMEOUT
# to export, honouring an explicit environment value, and refusing one that is
# not strictly below the suite bound. Maestro throws IOSDriverTimeoutException
# ("iOS driver not ready in time") when this expires - a real, retryable failure
# the maestro scripts rerun once. With the value at or above the bound the bound
# fires first, exits 124, and 124 is never retried: a driver that failed to
# launch (`TEST EXECUTE FAILED` in xctest_runner_*.log, seen at 77s on a loaded
# runner) then costs the whole bound and zero flows run. Healthy runner startups
# measured 86s and 144s; 300000 leaves 2x headroom and half the bound for flows.
workflows_driver_startup_timeout() {
  local default_ms="${1:?usage: workflows_driver_startup_timeout DEFAULT_MS}"
  local ms="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-$default_ms}"
  local bound_ms=$((WORKFLOWS_SUITE_TIMEOUT_MINUTES * 60 * 1000))
  case "$ms" in *[!0-9]* | '') die "MAESTRO_DRIVER_STARTUP_TIMEOUT must be milliseconds, got '$ms'" ;; esac
  [ "$ms" -lt "$bound_ms" ] ||
    die "MAESTRO_DRIVER_STARTUP_TIMEOUT=$ms is not below the suite bound (${bound_ms}ms): a driver that fails to start would burn the bound (exit 124, never retried) instead of failing fast and being retried"
  printf '%s\n' "$ms"
}

# workflows_assert_suite_ran JUNIT_PATH PLATFORM - fail when the suite ran no tests.
#
# Maestro exits 0 when its flow selection matches nothing at all: a tag filter
# that no flow carries, a renamed .maestro/flows directory, a config.yaml whose
# includeTags stopped matching. The job then goes green having tested nothing,
# which is the most expensive kind of pass - it is indistinguishable from a real
# one, and it stays green until someone ships a broken build.
#
# The junit report Maestro already writes carries the count, so no extra run is
# needed. Only the `tests` attribute is read here; whether individual tests
# failed is already in Maestro's own exit status.
workflows_assert_suite_ran() {
  local junit="$1" platform="$2" tests
  if [ ! -f "$junit" ]; then
    die "$platform: Maestro reported success but wrote no junit report at $junit - the suite cannot be shown to have run"
  fi
  # The attribute off the <testsuites>/<testsuite> element. sed rather than an
  # XML parser: the runners have no xmllint guarantee, and this is one attribute
  # in a file Maestro generates to a fixed shape.
  tests="$(sed -n 's/.*[^a-zA-Z]tests="\([0-9][0-9]*\)".*/\1/p' "$junit" | head -1)"
  if [ -z "$tests" ]; then
    die "$platform: no tests= count in $junit - cannot confirm the suite ran"
  fi
  if [ "$tests" -eq 0 ]; then
    die "$platform: Maestro exited 0 but ran 0 flows. Check the flows directory and the tag filters (WORKFLOWS_MAESTRO_INCLUDE_TAGS='${WORKFLOWS_MAESTRO_INCLUDE_TAGS:-}', WORKFLOWS_MAESTRO_EXCLUDE_TAGS='${WORKFLOWS_MAESTRO_EXCLUDE_TAGS:-}') - a suite that selects nothing passes without testing anything."
  fi
  log "$platform: Maestro ran $tests flow(s)"
}
