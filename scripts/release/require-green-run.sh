#!/usr/bin/env bash
# Block until a named workflow's run for a given sha has finished successfully.
#
# The point is ordering, not information: promoting a build to a store when the
# internal release workflow for the same commit is still running (or has failed)
# ships an unverified binary. So a failure or cancellation is fatal, and so is
# "no run of that workflow exists for this sha at all" - a silently-skipped gate
# is the failure mode this script exists to prevent.
#
# Self-healing, when asked: with REQUIRE_GREEN_DISPATCH_REF set, a missing,
# cancelled or failed run is dispatched once (`gh workflow run WORKFLOW --ref
# REF`) and the gate then waits for *that* run. The ref is a tag, so the
# dispatched run builds exactly the gated commit. This is what makes "merge
# whenever" safe: a release PR merged behind another push used to lose its
# internal build to concurrency-group eviction and the beta then failed here,
# waiting for a human to dispatch by hand. A dispatched run that also fails is
# fatal - nothing is retried forever. `skipped` is never dispatched: that is a
# path filter saying the commit needs no build, and a dispatch would not change
# it. Dispatching needs `actions: write` on the calling job.
#
# Usage: require-green-run.sh WORKFLOW_FILE SHA
# Env: WORKFLOWS_GREEN_TIMEOUT_MINUTES (45), WORKFLOWS_GREEN_DISCOVERY_MINUTES (5),
#      WORKFLOWS_GREEN_POLL_SECONDS (30), REQUIRE_GREEN_DISPATCH_REF (''), GH_TOKEN.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh yq

workflow="${1:?usage: require-green-run.sh WORKFLOW_FILE SHA}"
sha="${2:?usage: require-green-run.sh WORKFLOW_FILE SHA}"

timeout_minutes="${WORKFLOWS_GREEN_TIMEOUT_MINUTES:-45}"
discovery_minutes="${WORKFLOWS_GREEN_DISCOVERY_MINUTES:-5}"
poll_seconds="${WORKFLOWS_GREEN_POLL_SECONDS:-30}"
dispatch_ref="${REQUIRE_GREEN_DISPATCH_REF:-}"
dispatched=false
superseded_run_id=""

# gh's stderr goes to a file of its own, never into the JSON on stdout: a
# notice on stderr from a call that succeeded (an update hint, a deprecation)
# made the JSON unparseable, which read as "no run" and dispatched a duplicate
# or died "never started".
gh_stderr_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/workflows-gh-run-list.XXXXXX")"
trap 'rm -f "$gh_stderr_file"' EXIT

now() { date +%s; }
start="$(now)"
deadline="$((start + timeout_minutes * 60))"
discovery_deadline="$((start + discovery_minutes * 60))"

log "waiting for $workflow on $sha (timeout ${timeout_minutes}m, discovery ${discovery_minutes}m${dispatch_ref:+, will dispatch at $dispatch_ref if missing or red})"

# Dispatch the gated workflow at the ref, once, and start the clock again for
# the run that dispatch creates. The run being replaced (if any) is remembered
# so the poll does not keep reading it as the newest run for the sha.
dispatch_once() {
  local why="$1" old_id="$2"
  if [ -z "$dispatch_ref" ]; then
    return 1
  fi
  if [ "$dispatched" = "true" ]; then
    log "$workflow was already dispatched once for $sha and $why - not dispatching again"
    return 1
  fi
  log "$why - dispatching $workflow at $dispatch_ref"
  gh workflow run "$workflow" --ref "$dispatch_ref" \
    || die "could not dispatch $workflow at $dispatch_ref (does the calling job grant actions: write?)"
  dispatched=true
  superseded_run_id="$old_id"
  start="$(now)"
  deadline="$((start + timeout_minutes * 60))"
  discovery_deadline="$((start + discovery_minutes * 60))"
  return 0
}

while :; do
  # `|| true`: a transient API error must not fail the gate on the first blip;
  # the loop retries and the overall timeout is the real bound.
  # The status is captured separately: a sustained auth or API failure and "no
  # run has started yet" produce the same empty result, and diagnosing an
  # outage as "the run was never started" sends the reader to the wrong repo.
  gh_failed=false
  runs="$(gh run list --workflow "$workflow" --commit "$sha" --json conclusion,status,databaseId 2>"$gh_stderr_file")" || gh_failed=true
  gh_stderr="$(tr '\n' ' ' < "$gh_stderr_file")"
  if [ "$gh_failed" = "true" ]; then
    gh_error="${gh_stderr:-$(printf '%s' "$runs" | tr '\n' ' ')}"
    runs=""
    log "gh run list failed: $gh_error"
  elif [ -n "$gh_stderr" ]; then
    log "gh run list succeeded with a notice: $gh_stderr"
  fi
  count=0
  if [ -n "$runs" ]; then
    count="$(printf '%s' "$runs" | yq -r 'length // 0' 2>/dev/null || echo 0)"
  fi

  run_id=""
  if [ "$count" -gt 0 ]; then
    run_id="$(printf '%s' "$runs" | yq -r '.[0].databaseId // ""')"
  fi
  if [ -n "$run_id" ] && [ "$run_id" = "$superseded_run_id" ]; then
    # The newest run for the sha is still the one the dispatch replaced.
    count=0
  fi
  if [ "$count" -gt 0 ]; then
    status="$(printf '%s' "$runs" | yq -r '.[0].status // ""')"
    conclusion="$(printf '%s' "$runs" | yq -r '.[0].conclusion // ""')"
    if [ "$status" = "completed" ]; then
      case "$conclusion" in
        success)
          log "$workflow run $run_id for $sha succeeded"
          gh_output run-id "$run_id"
          exit 0
          ;;
        skipped)
          die "$workflow run $run_id for $sha was skipped - nothing verified this commit"
          ;;
        *)
          dispatch_once "$workflow run $run_id for $sha concluded '$conclusion'" "$run_id" \
            || die "$workflow run $run_id for $sha concluded '$conclusion' - refusing to continue"
          ;;
      esac
    else
      log "$workflow run $run_id is $status; polling again in ${poll_seconds}s"
    fi
  else
    if [ "$(now)" -ge "$discovery_deadline" ]; then
      if [ "$gh_failed" = "true" ]; then
        die "could not query runs of $workflow for $sha within ${discovery_minutes}m - every 'gh run list' failed, the last with: ${gh_error:-unknown error}. This is an API/permissions problem (does the calling job grant actions: read?), not a missing run"
      fi
      dispatch_once "no $workflow run found for $sha within ${discovery_minutes}m" "" \
        || die "no $workflow run found for $sha within ${discovery_minutes}m - it was never started"
    else
      log "no $workflow run for $sha yet; polling again in ${poll_seconds}s"
    fi
  fi

  [ "$(now)" -lt "$deadline" ] || die "$workflow did not complete for $sha within ${timeout_minutes}m"
  sleep "$poll_seconds"
done
