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

# The dispatch needs `actions: write`; the release-please job has no
# job-level block by design (a job-level block would replace the top-level
# one), so the scope has to be granted at the top of the file.
@test "self-release.yml grants actions: write at the top, for the dispatch" {
  [ "$(yq -r '.permissions.actions' "$RELEASE")" = "write" ] \
    || fail "self-release.yml top-level permissions.actions is '$(yq -r '.permissions.actions' "$RELEASE")', not write"
  [ "$(yq -r '.jobs."release-please" | has("permissions")' "$RELEASE")" = "false" ] \
    || fail "the release-please job declares its own permissions block, which replaces the top-level grant"
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
