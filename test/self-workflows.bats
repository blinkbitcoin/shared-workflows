#!/usr/bin/env bats
load test_helper

# The self-* workflows are excluded from workflow-shape.bats (they are this
# repo's own CI, not the family consumers call). Their invariants live here.

CI="$REPO_ROOT/.github/workflows/self-ci.yml"
RELEASE="$REPO_ROOT/.github/workflows/self-release.yml"

# A release PR opened with GITHUB_TOKEN gets a pull_request run GitHub never
# gives a job. workflow_dispatch is the one event that token still fires, so
# self-release.yml starts CI on the PR's branch by name - which needs the
# trigger to exist.
@test "self-ci.yml can be dispatched by name" {
  [ "$(yq -r '.on | has("workflow_dispatch")' "$CI")" = "true" ] \
    || fail "self-ci.yml has no workflow_dispatch trigger; self-release.yml cannot start it on the release PR"
}

@test "self-ci.yml still runs on push to main and on pull_request" {
  [ "$(yq -r '.on.push.branches | join(",")' "$CI")" = "main" ] \
    || fail "self-ci.yml push trigger changed: $(yq -r '.on.push' "$CI")"
  [ "$(yq -r '.on | has("pull_request")' "$CI")" = "true" ] \
    || fail "self-ci.yml lost its pull_request trigger"
}

# The dispatch needs `actions: write`, and release-please needs contents and
# pull-requests. All three are granted on the release-please job, not at the
# top: a job-level block replaces the top-level one, so a write grant at the top
# would reach every job added later (zizmor's excessive-permissions).
@test "self-release.yml grants the release-please job its writes, and nothing at the top" {
  for scope in contents pull-requests actions; do
    got="$(yq -r ".jobs.\"release-please\".permissions.\"$scope\"" "$RELEASE")"
    [ "$got" = "write" ] || fail "release-please job permissions.$scope is '$got', not write"
  done
  top="$(yq -r '[.permissions // {} | to_entries[] | select(.value == "write") | .key] | join(",")' "$RELEASE")"
  [ -z "$top" ] || fail "self-release.yml grants '$top' at the top level; grant writes per job"
}

@test "self-release.yml starts self-ci on the release PR only when a PR was created" {
  step="$(yq -r '.jobs."release-please".steps[] | select(.run != null and (.run | test("dispatch-release-pr-ci.sh")))' "$RELEASE")"
  [ -n "$step" ] || fail "no step in self-release.yml runs scripts/self/dispatch-release-pr-ci.sh"
  cond="$(yq -r '.if' <<<"$step")"
  [[ "$cond" == *"steps.release.outputs.prs_created == 'true'"* ]] \
    || fail "the dispatch step is not gated on prs_created == 'true': $cond"
  [ "$(yq -r '.env.PRS_JSON' <<<"$step")" = '${{ steps.release.outputs.prs }}' ] \
    || fail "the dispatch step does not pass release-please's prs output as PRS_JSON"
  [ "$(yq -r '.env.GH_REPO' <<<"$step")" = '${{ github.repository }}' ] \
    || fail "the dispatch step does not set GH_REPO"
}

# The script dispatches self-ci.yml by name. A rename of the workflow file
# would leave it dispatching a name that no longer exists, failing only on a
# real release - so the name is held to the file here.
@test "the dispatch script names a workflow file that exists" {
  grep -q 'gh workflow run self-ci.yml' "$REPO_ROOT/scripts/self/dispatch-release-pr-ci.sh" \
    || fail "dispatch-release-pr-ci.sh no longer dispatches self-ci.yml by that name"
  [ -f "$CI" ] || fail "self-ci.yml is gone; the dispatch script still names it"
}

# One release PR per package, and both bump adjacent lines of the shared
# manifest: merging one leaves the other conflicting. release-please rebuilds
# an open PR only when its notes change - unless always-update is set, which
# rebuilds every open one on each push to main. Without it the other PR sits
# conflicting until someone rebases it by hand (#55, #76).
@test "release-please rebuilds every open release PR, so two PRs cannot leave each other conflicting" {
  config="$REPO_ROOT/release-please-config.json"
  [ "$(jq -r '."always-update"' "$config")" = "true" ] \
    || fail "release-please-config.json has separate-pull-requests without always-update; a release of one package leaves the other's PR conflicting on .release-please-manifest.json"
}

# --------------------------------------------------------------------------
# The gate list and the job list, held together.
#
# self-ci.yml used to run `make check` as one job, which made "CI runs every
# gate" true by construction. Splitting it into a job per gate - so a run graph
# names the one that failed - gives up that guarantee: a target added to
# `check:` would be enforced by the pre-push hook and by no CI job at all. That
# is the same drift consumer-contract.bats exists to catch on the consumer
# side, and it is caught here the same way, by reading both lists rather than
# keeping a third by hand.
# --------------------------------------------------------------------------
SELF_CHECKS="$REPO_ROOT/.github/workflows/self-checks.yml"
SELF_UNIT="$REPO_ROOT/.github/workflows/self-unit.yml"

# The targets `make check` depends on, read out of the Makefile at run time.
check_prerequisites() {
  local line deps
  line="$(grep -E '^check:' "$REPO_ROOT/Makefile" | head -1)"
  deps="${line#check:}"
  deps="${deps%%##*}"
  tr ' ' '\n' <<<"$deps" | sed '/^$/d' | sort -u
}

# Every make target some job in the two called workflows actually runs. A step
# may name several (`make shellcheck actionlint`), so the line is split too.
ci_make_targets() {
  local f
  for f in "$SELF_CHECKS" "$SELF_UNIT"; do
    yq -r '[.jobs[].steps[] | .run // ""] | .[]' "$f"
  done | sed -nE 's/^[[:space:]]*make[[:space:]]+([a-z0-9 _-]+)$/\1/p' \
    | tr ' ' '\n' | sed '/^$/d' | sort -u
}

@test "every gate make check depends on is run by a self-CI job" {
  command -v yq >/dev/null || skip "yq not installed"
  local missing=()
  while IFS= read -r target; do
    ci_make_targets | grep -qx "$target" || missing+=("$target")
  done < <(check_prerequisites)
  [ "${#missing[@]}" -eq 0 ] \
    || fail "make check runs these gates and no self-CI job does: ${missing[*]}"
}

# The other direction. A job running a target that `make check` does not reach
# is a gate CI enforces and `make check` does not, so a green local run would
# be a claim about coverage it does not have.
@test "every make target a self-CI job runs is reachable from make check" {
  command -v yq >/dev/null || skip "yq not installed"
  local extra=()
  while IFS= read -r target; do
    check_prerequisites | grep -qx "$target" || extra+=("$target")
  done < <(ci_make_targets)
  [ "${#extra[@]}" -eq 0 ] \
    || fail "these self-CI jobs run a target make check does not: ${extra[*]}"
}

# The extractors are the load-bearing part: one that silently found nothing
# would make both cases above pass by vacuum.
@test "the self-CI extractors find the gates and the jobs" {
  command -v yq >/dev/null || skip "yq not installed"
  [ "$(check_prerequisites | wc -l)" -ge 5 ] \
    || fail "check_prerequisites found almost nothing: $(check_prerequisites | tr '\n' ' ')"
  [ "$(ci_make_targets | wc -l)" -ge 5 ] \
    || fail "ci_make_targets found almost nothing: $(ci_make_targets | tr '\n' ' ')"
}

# --- which gates a change runs ------------------------------------------------
#
# self-ci.yml's `changes` job classifies the diff with scripts/self/changed-gates.sh
# (its cases are in changed-gates.bats) and hands each narrow gate a boolean.
# These cases hold the wiring: every class reaches its job, and the gates that
# read the whole tree or the whole history carry no class at all.

CHECKS="$REPO_ROOT/.github/workflows/self-checks.yml"
UNIT="$REPO_ROOT/.github/workflows/self-unit.yml"

@test "self-ci.yml classifies with changed-gates.sh against the PR base only" {
  command -v yq >/dev/null || skip "yq not installed"
  step=$(yq -r '.jobs.changes.steps[] | select(.id == "classify")' "$CI")
  contains "$step" 'bash scripts/self/changed-gates.sh "$BASE_SHA" "$HEAD_SHA"' \
    || fail "the classify step does not run changed-gates.sh: $step"
  # PR only: a push to main and the release PR's dispatch then have no base and
  # run every gate, so main's push run - the one that counts - stays complete.
  [ "$(yq -r '.jobs.changes.steps[] | select(.id == "classify") | .env.BASE_SHA' "$CI")" \
    = '${{ github.event.pull_request.base.sha }}' ] || fail "BASE_SHA is not the PR base alone"
  [ "$(yq -r '.jobs.changes.steps[0].with."fetch-depth"' "$CI")" = "0" ] \
    || fail "the changes checkout is shallow; the base would be absent"
}

@test "self-ci.yml hands each class to its gate, reading an empty output as run" {
  command -v yq >/dev/null || skip "yq not installed"
  for pair in checks:code checks:tooling unit:package; do
    job="${pair%%:*}" class="${pair##*:}"
    [ "$(yq -r ".jobs.$job.needs" "$CI")" = "changes" ] || fail "$job does not need changes"
    [ "$(yq -r ".jobs.$job.with.$class" "$CI")" = "\${{ needs.changes.outputs.$class != 'false' }}" ] \
      || fail "$job does not pass $class as != 'false': $(yq -r ".jobs.$job.with" "$CI")"
    [ "$(yq -r ".jobs.changes.outputs.$class" "$CI")" = "\${{ steps.classify.outputs.$class }}" ] \
      || fail "the changes job does not expose $class"
  done
}

@test "each narrow gate runs on its input, which defaults to true" {
  command -v yq >/dev/null || skip "yq not installed"
  for spec in "$CHECKS:code:code" "$CHECKS:tooling:tooling" "$UNIT:package:package"; do
    file="${spec%%:*}" rest="${spec#*:}"
    job="${rest%%:*}" input="${rest##*:}"
    [ "$(yq -r ".jobs.$job.if" "$file")" = "\${{ inputs.$input }}" ] \
      || fail "$(basename "$file") $job is not gated on inputs.$input"
    [ "$(yq -r ".on.workflow_call.inputs.$input.default" "$file")" = "true" ] \
      || fail "$(basename "$file") input $input does not default to true"
  done
}

@test "the gates that read the whole tree or history carry no class" {
  command -v yq >/dev/null || skip "yq not installed"
  for job in security docs; do
    [ "$(yq -r ".jobs.$job.if // \"\"" "$CHECKS")" = "" ] || fail "self-checks.yml $job gained an if"
  done
  [ "$(yq -r '.jobs.commits.if' "$CHECKS")" = "github.event_name == 'pull_request'" ] \
    || fail "commits is gated on more than the event: $(yq -r '.jobs.commits.if' "$CHECKS")"
  [ "$(yq -r '.jobs.tests.if // ""' "$UNIT")" = "" ] || fail "self-unit.yml tests gained an if"
}
