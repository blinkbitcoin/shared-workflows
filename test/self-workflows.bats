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
# pull-requests. All three are granted on the release-pr job, not at the
# top: a job-level block replaces the top-level one, so a write grant at the top
# would reach every job added later (zizmor's excessive-permissions).
@test "self-release.yml grants the release-pr job its writes, and nothing at the top" {
  for scope in contents pull-requests actions; do
    got="$(yq -r ".jobs.\"release-pr\".permissions.\"$scope\"" "$RELEASE")"
    [ "$got" = "write" ] || fail "release-pr job permissions.$scope is '$got', not write"
  done
  top="$(yq -r '[.permissions // {} | to_entries[] | select(.value == "write") | .key] | join(",")' "$RELEASE")"
  [ -z "$top" ] || fail "self-release.yml grants '$top' at the top level; grant writes per job"
}

# self-release.yml keeps its release PR open with the same reusable workflow a
# consumer calls, from this commit, and has it start self-ci.yml on each release
# PR. How that workflow gates and wires the dispatch is held in
# workflow-shape.bats; here, that this repository uses it that way.
@test "self-release.yml runs the local pr-release.yml, starting self-ci on each release PR" {
  [ "$(yq -r '.jobs."release-pr".uses' "$RELEASE")" = "./.github/workflows/pr-release.yml" ] \
    || fail "self-release.yml does not call the local pr-release.yml: $(yq -r '.jobs."release-pr".uses' "$RELEASE")"
  [ "$(yq -r '.jobs."release-pr".with."ci-workflow"' "$RELEASE")" = "self-ci.yml" ] \
    || fail "self-release.yml does not start self-ci.yml on the release PR"
  for secret in RELEASE_TAGGER_APP_ID RELEASE_TAGGER_APP_PRIVATE_KEY RELEASE_PLEASE_TOKEN; do
    [ "$(yq -r ".jobs.\"release-pr\".secrets.$secret" "$RELEASE")" = "\${{ secrets.$secret }}" ] \
      || fail "self-release.yml does not pass $secret"
  done
}

# The CI workflow is named in self-release.yml. A rename of the file would leave
# the release PR dispatching a name that no longer exists, failing only on a real
# release - so the name is held to the file here.
@test "the CI workflow self-release.yml starts on the release PR exists" {
  ci="$(yq -r '.jobs."release-pr".with."ci-workflow"' "$RELEASE")"
  [ -f "$REPO_ROOT/.github/workflows/$ci" ] || fail "self-release.yml starts $ci, which does not exist"
}

# The npm package releases on its own cadence: its job keys off paths-released,
# and a path spelled wrong there would skip the publish rather than fail it.
@test "self-release.yml publishes app-tooling only when that package released" {
  cond="$(yq -r '.jobs."publish-app-tooling".if' "$RELEASE")"
  [ "$cond" = "\${{ contains(fromJSON(needs.release-pr.outputs.paths-released || '[]'), 'packages/app-tooling') }}" ] \
    || fail "publish-app-tooling is not gated on packages/app-tooling being released: $cond"
  [ -f "$REPO_ROOT/packages/app-tooling/package.json" ] || fail "packages/app-tooling moved; the gate names a path that is gone"
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
# The store notes dry run: pr-store-notes.yml, executed for real.
#
# Every other reusable workflow runs only inside a consumer, so a mistake in
# one ships with every gate here green. self-store-notes.yml runs this one
# against the template in a dry run, on every change and before `v0` moves.
# --------------------------------------------------------------------------
SELF_STORE_NOTES="$REPO_ROOT/.github/workflows/self-store-notes.yml"

@test "self-store-notes.yml runs the local pr-store-notes.yml against the template in a dry run" {
  require_cmd yq
  [ "$(yq -r '.on | has("workflow_call")' "$SELF_STORE_NOTES")" = "true" ] || fail "self-store-notes.yml is not callable"
  [ "$(yq -r '.jobs."dry-run".name' "$SELF_STORE_NOTES")" = "Dry run" ] || fail "the dry run job was renamed"
  [ "$(yq -r '.jobs.draft.name' "$REPO_ROOT/.github/workflows/pr-store-notes.yml")" = "Draft" ] \
    || fail "pr-store-notes.yml's job was renamed"
  # Local, not @v0: the dry run has to run the ref under review.
  [ "$(yq -r '.jobs."dry-run".uses' "$SELF_STORE_NOTES")" = "./.github/workflows/pr-store-notes.yml" ] \
    || fail "the dry run does not call the local pr-store-notes.yml: $(yq -r '.jobs."dry-run".uses' "$SELF_STORE_NOTES")"
  [ "$(yq -r '.jobs."dry-run".with.repository' "$SELF_STORE_NOTES")" = "blinkbitcoin/react-native-mobile-template" ] \
    || fail "the dry run no longer targets the template"
  [ "$(yq -r '.jobs."dry-run".with.ref' "$SELF_STORE_NOTES")" = "main" ] || fail "the dry run no longer reads the template's main"
  [ "$(yq -r '.jobs."dry-run".with."dry-run"' "$SELF_STORE_NOTES")" = "true" ] || fail "the dry-run input is off - it would edit a PR"
  [ "$(yq -r '.jobs."dry-run".with."body-file"' "$SELF_STORE_NOTES")" = ".workflows/packages/app-tooling/fixtures/store-notes/release-body.md" ] \
    || fail "the dry run reads no body file, so it would need a release PR"
  [ "$(yq -r '.jobs."dry-run".with."pr-number" // ""' "$SELF_STORE_NOTES")" = "" ] || fail "the dry run names a PR"
  [ "$(yq -r '.jobs."dry-run".secrets // "none"' "$SELF_STORE_NOTES")" = "none" ] || fail "the dry run passes secrets"
  [ "$(yq -r '.jobs."dry-run".permissions."pull-requests"' "$SELF_STORE_NOTES")" = "write" ] \
    || fail "the dry run does not grant what pr-store-notes.yml's job declares"
}

@test "self-store-notes.yml checks the section output with its own script" {
  require_cmd yq
  [ "$(yq -r '.jobs."validate".name' "$SELF_STORE_NOTES")" = "Validate" ] || fail "the validate job was renamed"
  [ "$(yq -r '.jobs.validate.needs' "$SELF_STORE_NOTES")" = "dry-run" ] || fail "the section check does not wait on the dry run"
  [ "$(yq -r '.jobs.validate."timeout-minutes"' "$SELF_STORE_NOTES")" != "null" ] || fail "the section check has no timeout"
  step="$(yq -r '.jobs.validate.steps[] | select(.run != null)' "$SELF_STORE_NOTES")"
  [ "$(yq -r '.run' <<<"$step")" = "bash scripts/self/check-store-notes-section.sh" ] \
    || fail "the section check does not run scripts/self/check-store-notes-section.sh: $step"
  [ "$(yq -r '.env.SECTION' <<<"$step")" = '${{ needs.dry-run.outputs.section }}' ] \
    || fail "the section check does not read the dry run's section output: $step"
  [ -f "$REPO_ROOT/scripts/self/check-store-notes-section.sh" ] || fail "the check script is gone"
}

@test "self-ci.yml runs the dry run on every change, with the grant the called job declares" {
  require_cmd yq
  [ "$(yq -r '.jobs."store-notes".uses' "$CI")" = "./.github/workflows/self-store-notes.yml" ] \
    || fail "self-ci.yml does not call self-store-notes.yml"
  [ "$(yq -r '.jobs."store-notes".name' "$CI")" = "Store notes" ] || fail "the store notes job was renamed"
  [ "$(yq -r '.jobs."store-notes".if // "always"' "$CI")" = "always" ] || fail "the dry run is gated: $(yq -r '.jobs."store-notes".if' "$CI")"
  [ "$(yq -r '.jobs."store-notes".permissions.contents' "$CI")" = "read" ] || fail "the dry run job does not grant contents: read"
  [ "$(yq -r '.jobs."store-notes".permissions."pull-requests"' "$CI")" = "write" ] \
    || fail "the dry run job does not grant pull-requests: write, so the called job cannot start"
}

# tag-major.sh force-moves `v0`, which every consumer resolves on its next run.
# A release whose dry run failed must leave the tags where they were.
@test "self-release.yml moves the major tag only after the release commit's dry run passed" {
  require_cmd yq
  [ "$(yq -r '.jobs."store-notes".uses' "$RELEASE")" = "./.github/workflows/self-store-notes.yml" ] \
    || fail "self-release.yml does not run the dry run"
  cond="$(yq -r '.jobs."store-notes".if' "$RELEASE")"
  [[ "$cond" == *"needs.release-pr.outputs.release-created == 'true'"* ]] \
    || fail "the dry run is not gated on a release: $cond"
  [ "$(yq -r '.jobs."store-notes".permissions."pull-requests"' "$RELEASE")" = "write" ] \
    || fail "the release dry run does not grant pull-requests: write"
  needs="$(yq -r '.jobs."major-tag".needs | (select(type == "!!seq") | join(",")) // .' "$RELEASE")"
  [[ ",$needs," == *",store-notes,"* ]] || fail "major-tag does not need the dry run: $needs"
  [[ ",$needs," == *",release-pr,"* ]] || fail "major-tag lost its release-pr need: $needs"
  [ "$(yq -r '.jobs."major-tag".if' "$RELEASE")" != "null" ] || fail "major-tag lost its if"
  # `always()` or `!cancelled()` would run it past a failed dry run.
  not_contains "$(yq -r '.jobs."major-tag".if' "$RELEASE")" "always()" || fail "major-tag runs past a failed dry run"
  not_contains "$(yq -r '.jobs."major-tag".if' "$RELEASE")" "cancelled()" || fail "major-tag runs past a failed dry run"
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
# may name several (`make check-ci`), so the line is split too.
ci_make_targets() {
  local f
  for f in "$SELF_CHECKS" "$SELF_UNIT"; do
    yq -r '[.jobs[].steps[] | .run // ""] | .[]' "$f"
  done | sed -nE 's/^[[:space:]]*make[[:space:]]+([a-z0-9 _-]+)$/\1/p' \
    | tr ' ' '\n' | sed '/^$/d' | sort -u
}

@test "every gate make check depends on is run by a self-CI job" {
  require_cmd yq
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
  require_cmd yq
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
  require_cmd yq
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
  require_cmd yq
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
  require_cmd yq
  for pair in checks:ci checks:versions unit:package; do
    job="${pair%%:*}" class="${pair##*:}"
    [ "$(yq -r ".jobs.$job.needs" "$CI")" = "changes" ] || fail "$job does not need changes"
    [ "$(yq -r ".jobs.$job.with.$class" "$CI")" = "\${{ needs.changes.outputs.$class != 'false' }}" ] \
      || fail "$job does not pass $class as != 'false': $(yq -r ".jobs.$job.with" "$CI")"
    [ "$(yq -r ".jobs.changes.outputs.$class" "$CI")" = "\${{ steps.classify.outputs.$class }}" ] \
      || fail "the changes job does not expose $class"
  done
}

@test "each narrow gate runs on its input, which defaults to true" {
  require_cmd yq
  for spec in "$CHECKS:ci:ci" "$CHECKS:versions:versions" "$UNIT:package:package"; do
    file="${spec%%:*}" rest="${spec#*:}"
    job="${rest%%:*}" input="${rest##*:}"
    [ "$(yq -r ".jobs.$job.if" "$file")" = "\${{ inputs.$input }}" ] \
      || fail "$(basename "$file") $job is not gated on inputs.$input"
    [ "$(yq -r ".on.workflow_call.inputs.$input.default" "$file")" = "true" ] \
      || fail "$(basename "$file") input $input does not default to true"
  done
}

@test "the gates that read the whole tree or history carry no class" {
  require_cmd yq
  for job in security docs; do
    [ "$(yq -r ".jobs.$job.if // \"\"" "$CHECKS")" = "" ] || fail "self-checks.yml $job gained an if"
  done
  [ "$(yq -r '.jobs.commits.if' "$CHECKS")" = "github.event_name == 'pull_request'" ] \
    || fail "commits is gated on more than the event: $(yq -r '.jobs.commits.if' "$CHECKS")"
  [ "$(yq -r '.jobs.tests.if // ""' "$UNIT")" = "" ] || fail "self-unit.yml tests gained an if"
}
