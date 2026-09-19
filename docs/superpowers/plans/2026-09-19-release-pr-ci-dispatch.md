# Release PR CI Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every release-please PR a real, green CI run by dispatching `self-ci.yml` on the PR's branch from `self-release.yml`, with no GitHub App or secret required.

**Architecture:** `workflow_dispatch` is the one event GitHub still fires for work done with `GITHUB_TOKEN`. After `release-please` reports `prs_created == 'true'`, a step in `self-release.yml` runs a small script that reads the PR's head branch from the action's `pr` output and calls `gh workflow run self-ci.yml --ref <branch>`. `self-ci.yml` gains a `workflow_dispatch` trigger so it can be started by name. The red, job-less `pull_request` run that GitHub creates for a `GITHUB_TOKEN`-opened PR stays (only the RELEASE_TAGGER App path already in `self-release.yml` removes it); this plan adds the green run beside it, exactly as the template's `release-please.yml` does today.

**Tech Stack:** GitHub Actions, `googleapis/release-please-action@v5` (`prs_created`, `pr` outputs), `gh` CLI, bash under `set -euo pipefail`, bats, yq.

**Spec:** The design was agreed in chat on 2026-09-19 (session `session_01SpyYZEnJaLFih75JB4EQAW`): dispatch now, App later. Reference implementation: `react-native-mobile-template/.github/workflows/release-please.yml`, step "Run CI on the release PR".

## Global Constraints

- Shell of more than a couple of lines lives under `scripts/<area>/` with a bats test, never inline in a workflow (AGENTS.md, "Rules of the road").
- Every bats assertion ends in `|| fail "..."` (`test/assertions-enforced.bats` enforces it).
- Every `run:` step in a workflow is a single `bash ...` line (`test/workflow-shape.bats`, "every run: step is a single 'bash ...' line"; self-* workflows are exempt from that suite but follow it anyway).
- A job-level `permissions:` block replaces the top-level one; the release-please job has none, so the extra scope goes at the top of `self-release.yml`.
- Commit scope for these files is `self` (`commitlint.config.mjs`); the type is `fix` so the change releases and its own release PR becomes the verification.
- `make check` must pass before every push (shellcheck, actionlint, bats, check-versions, tool-versions, typos).
- Run every make target from the repo root; `mise exec --` is applied by the Makefile.

**Deviation recorded during execution:** the script reads release-please's
`prs` output (env `PRS_JSON`, a JSON array) and dispatches once per PR,
because the action's singular `pr` output is only `prs[0]`
(release-please-action v5 `src/index.ts`, `outputPRs()`) and this repo's
`release-please-config.json` sets `separate-pull-requests: true` over two
packages; Tasks 2 and 3 below show the original single-PR form, and the code
on the branch is the plural form.

---

### Task 1: `self-ci.yml` accepts `workflow_dispatch`

**Files:**
- Modify: `.github/workflows/self-ci.yml:1-9` (the `on:` block)
- Test: `test/self-workflows.bats` (create)

**Interfaces:**
- Produces: `self-ci.yml` runnable by `gh workflow run self-ci.yml --ref <branch>`. Its `pr-title` job is already gated on `github.event_name == 'pull_request'` and is skipped on dispatch; `check` and `parity` run.

- [ ] **Step 1: Write the failing test**

Create `test/self-workflows.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/jonas/Dev/blink/shared-workflows && mise exec -- bats test/self-workflows.bats`
Expected: `not ok 1 self-ci.yml can be dispatched by name` with the message "has no workflow_dispatch trigger"; test 2 `ok`.

- [ ] **Step 3: Add the trigger**

In `.github/workflows/self-ci.yml`, replace the `on:` block (lines 2-9) with:

```yaml
on:
  push: { branches: [main] }
  # No filter for the release PR here: `branches-ignore` under pull_request
  # matches the PR's *base* branch, so a `release-please--**` entry matched
  # nothing (0.6.1 to 0.7.0 still carried the red run), and no filter could
  # help - GitHub creates the run before it reads this file. See
  # self-release.yml for why that run has no jobs, and for the fix.
  pull_request:
  # Started by name from self-release.yml on the release PR's branch: the one
  # event GitHub still fires for a PR opened with GITHUB_TOKEN. The pr-title
  # job is gated on the pull_request event and is skipped here.
  workflow_dispatch:
```

- [ ] **Step 4: Run the test to verify it passes, then the gate**

Run: `mise exec -- bats test/self-workflows.bats && make check`
Expected: `ok 1`, `ok 2`; `make check` exits 0 (actionlint accepts an empty `workflow_dispatch:`).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/self-ci.yml test/self-workflows.bats
git commit -m "fix(self): let self-ci.yml be dispatched by name

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 2: `scripts/self/dispatch-release-pr-ci.sh`

**Files:**
- Create: `scripts/self/dispatch-release-pr-ci.sh`
- Test: `test/dispatch-release-pr-ci.bats` (create)

**Interfaces:**
- Consumes: env `PR_JSON` (release-please's `pr` output, a JSON object with `headBranchName`), `GH_TOKEN`, `GH_REPO` (`owner/name`), and `gh` on PATH.
- Produces: one call `gh workflow run self-ci.yml --repo "$GH_REPO" --ref "<headBranchName>"`. Exit 1 with an `::error::` line when `PR_JSON` is empty or has no `headBranchName`.

- [ ] **Step 1: Write the failing tests**

Create `test/dispatch-release-pr-ci.bats`:

```bash
#!/usr/bin/env bats
load test_helper

SCRIPT="$REPO_ROOT/scripts/self/dispatch-release-pr-ci.sh"

setup() {
  # A fake gh that records its arguments; the script must never reach GitHub
  # from a test.
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/gh.args"\n' "$BATS_TEST_TMPDIR" > "$bin/gh"
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
  export GH_TOKEN=fake GH_REPO=blinkbitcoin/shared-workflows
}

@test "dispatches self-ci.yml on the release PR's head branch" {
  PR_JSON='{"headBranchName":"release-please--branches--main--components--shared-workflows","number":40}' \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  args="$(tr '\n' ' ' < "$BATS_TEST_TMPDIR/gh.args")"
  contains "$args" "workflow run self-ci.yml" || fail "args: $args"
  contains "$args" "--repo blinkbitcoin/shared-workflows" || fail "args: $args"
  contains "$args" "--ref release-please--branches--main--components--shared-workflows" || fail "args: $args"
}

@test "an empty PR_JSON is an error, not a silent skip" {
  PR_JSON='' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 with no PR"
  contains "$output" "::error::" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway"
}

@test "a PR without headBranchName is an error naming the missing field" {
  PR_JSON='{"number":40}' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 without a branch"
  contains "$output" "headBranchName" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway"
}

@test "fails without GH_REPO" {
  unset GH_REPO
  PR_JSON='{"headBranchName":"x"}' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 without GH_REPO"
  contains "$output" "GH_REPO" || fail "output: $output"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- bats test/dispatch-release-pr-ci.bats`
Expected: all four `not ok` (the script does not exist: "No such file or directory").

- [ ] **Step 3: Write the script**

Create `scripts/self/dispatch-release-pr-ci.sh`:

```bash
#!/usr/bin/env bash
# Start self-ci.yml on the release PR's branch, by name.
#
# release-please opens its PR with GITHUB_TOKEN, and GitHub creates a
# pull_request run for that PR but never gives it a job - it is marked failed
# the moment the PR merges. workflow_dispatch is the one event GitHub still
# fires for work done with that token, so this is how the PR gets a CI run
# that actually executes. The red run stays beside it until the release PR
# is opened by the RELEASE_TAGGER App instead (self-release.yml).
#
# The branch is read here, in the shell, not with fromJSON() in the step's
# `env:`: the runner validates a step's env expressions even when its `if` is
# false, and fromJSON('') is a template error (it failed the template's
# release job on its first no-PR push).
#
# Usage: dispatch-release-pr-ci.sh
# Env: PR_JSON (release-please's `pr` output), GH_TOKEN, GH_REPO
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh jq
: "${GH_REPO:?GH_REPO not set (owner/name)}"

[ -n "${PR_JSON:-}" ] || die "PR_JSON is empty: release-please reported a PR but passed no pr output"
branch="$(jq -r '.headBranchName // empty' <<<"$PR_JSON")" \
  || die "PR_JSON is not valid JSON: $PR_JSON"
[ -n "$branch" ] || die "release-please's pr output has no headBranchName: $PR_JSON"

log "dispatching self-ci.yml on $branch"
gh workflow run self-ci.yml --repo "$GH_REPO" --ref "$branch"
```

Then: `chmod +x scripts/self/dispatch-release-pr-ci.sh`

- [ ] **Step 4: Run the tests to verify they pass, then the gate**

Run: `mise exec -- bats test/dispatch-release-pr-ci.bats && make check`
Expected: 4 `ok`; `make check` exits 0 (shellcheck clean; `jq` is on every ubuntu runner and on this machine via the act image and Homebrew — if `make check` reports `missing command: jq` locally, install it with `brew install jq`; do not add it to `.mise.toml` for this).

- [ ] **Step 5: Commit**

```bash
git add scripts/self/dispatch-release-pr-ci.sh test/dispatch-release-pr-ci.bats
git commit -m "fix(self): add the script that starts self-ci on the release PR's branch

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 3: `self-release.yml` dispatches CI after opening the PR

**Files:**
- Modify: `.github/workflows/self-release.yml:8-10` (top-level `permissions`) and the step list after "Release please" (around line 45-55)
- Modify: `test/self-workflows.bats` (append two tests)
- Modify: `AGENTS.md` (the "Releases are release-please's job" bullet under "Rules of the road")

**Interfaces:**
- Consumes: Task 1's `workflow_dispatch` trigger; Task 2's script and its env contract (`PR_JSON`, `GH_TOKEN`, `GH_REPO`).
- Produces: on every push to main that opens or updates the release PR, a `workflow_dispatch` run of `self-ci.yml` on branch `release-please--branches--main--components--shared-workflows`.

- [ ] **Step 1: Write the failing tests**

Append to `test/self-workflows.bats`:

```bash
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
  [ "$(yq -r '.env.PR_JSON' <<<"$step")" = '${{ steps.release.outputs.pr }}' ] \
    || fail "the dispatch step does not pass release-please's pr output as PR_JSON"
  [ "$(yq -r '.env.GH_REPO' <<<"$step")" = '${{ github.repository }}' ] \
    || fail "the dispatch step does not set GH_REPO"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- bats test/self-workflows.bats`
Expected: tests 3 and 4 `not ok` ("permissions.actions is 'null'", "no step ... runs scripts/self/dispatch-release-pr-ci.sh"); tests 1 and 2 `ok`.

- [ ] **Step 3: Edit the workflow**

In `.github/workflows/self-release.yml`, change the top-level permissions block (lines 8-10) to:

```yaml
permissions:
  contents: write
  pull-requests: write
  # `gh workflow run` in the dispatch step below. Top-level because the
  # release-please job carries no block of its own.
  actions: write
```

Then, directly after the step named `Record which packages released` (the last step of the `release-please` job), add:

```yaml
      # The release PR is opened with GITHUB_TOKEN, so its own pull_request
      # run never gets a job (see the App step above for the full story and
      # the way to make that run real). workflow_dispatch is the one event
      # that token still fires: start self-ci.yml on the PR's branch by name,
      # once per push that creates or updates the PR. The branch is read in
      # the script, not with fromJSON() in `env:` - the runner validates a
      # step's env even when its `if` is false, and fromJSON('') is an error.
      - name: Run CI on the release PR
        if: ${{ steps.release.outputs.prs_created == 'true' }}
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          PR_JSON: ${{ steps.release.outputs.pr }}
        run: bash scripts/self/dispatch-release-pr-ci.sh
```

Note: the job has no `actions/checkout` step today (release-please needs none). Add one as the job's first step so the script exists on the runner:

```yaml
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
```

Place it before the "Mint an App token" step.

- [ ] **Step 4: Run the tests to verify they pass, then the gate**

Run: `mise exec -- bats test/self-workflows.bats && make check`
Expected: 4 `ok`; `make check` exits 0. If `test/workflow-shape.bats`'s "contents: write is asked for by exactly the three jobs that write" fails, the edit touched a job-level block by mistake: the grant must be top-level only.

- [ ] **Step 5: Update AGENTS.md**

In `AGENTS.md`, replace the bullet that begins `- **Releases are release-please's job.**` with:

```markdown
- **Releases are release-please's job.** `self-release.yml` cuts the version
  and re-points the moving `v0`/`v0.1` tags through
  `scripts/self/tag-major.sh`; never move a tag or edit a version by hand.
  The release PR it opens carries two CI runs: a red `pull_request` run that
  GitHub creates for a `GITHUB_TOKEN`-opened PR and never gives a job, and a
  green `workflow_dispatch` run that `scripts/self/dispatch-release-pr-ci.sh`
  starts on the PR's branch. The green one is the signal. The red one goes
  away only when the PR is opened by the RELEASE_TAGGER App (the guarded
  step in `self-release.yml`; needs the App's two secrets on this repo).
```

Run: `make check` — `test/docs-contract.bats` checks the command table only, so this passes as long as the markdown is well-formed and typos finds nothing.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/self-release.yml test/self-workflows.bats AGENTS.md
git commit -m "fix(self): start self-ci on the release PR by name, so the PR has a CI run with jobs

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 4: Push, PR, and verify on the release it produces

**Files:**
- None new. This task is the end-to-end check that the previous three cannot give locally: `act` cannot run `self-release.yml` (it needs the release-please action against GitHub), and the dispatch can only be observed on GitHub.

**Interfaces:**
- Consumes: the three commits above on one branch.
- Produces: evidence, recorded in the PR, that the release PR for this very change got a green dispatched CI run.

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin fix/release-pr-ci-dispatch
gh pr create --title "fix(self): start self-ci on the release PR by name, so the PR has a CI run with jobs" --body "$(cat <<'EOF'
The release PR is opened with GITHUB_TOKEN, so its pull_request CI run never gets a job and is marked failed at merge (every release since 0.3.1). #39 makes that run real once the RELEASE_TAGGER App is configured; until then, and as the template already does, this starts self-ci.yml on the PR's branch with workflow_dispatch, the one event GITHUB_TOKEN still fires. The red run stays beside the green one until the App exists.

- self-ci.yml gains a workflow_dispatch trigger (pr-title is gated on pull_request and skips).
- scripts/self/dispatch-release-pr-ci.sh reads release-please's `prs` output (the array; the singular `pr` is only the first PR, and with separate-pull-requests the dev-config PR would otherwise never get its CI) and runs `gh workflow run self-ci.yml --ref <branch>` once per PR; empty, malformed, non-array, empty-array or missing-headBranchName input is an error before any dispatch, never a skip. bats-covered against a fake gh.
- self-release.yml grants actions: write at the top (its job has no block by design) and runs the script when prs_created == 'true'.

Verification: the release PR this change produces should show a green `CI` run with event `workflow_dispatch` on its branch, next to the usual red pull_request one. Recorded below once it exists.

https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW
EOF
)"
gh pr checks --watch --fail-fast
```

Expected: `Check`, `Parity`, `PR title` all pass.

- [ ] **Step 2: Merge, then watch the release PR's runs**

After the PR is merged (a human merges; do not self-merge), release-please opens or updates the release PR on `release-please--branches--main--components--shared-workflows`. Then:

```bash
gh run list -R blinkbitcoin/shared-workflows -b release-please--branches--main--components--shared-workflows --limit 4 --json databaseId,event,conclusion,createdAt,displayTitle
```

Expected: two runs for the newest release PR commit: one `event=pull_request` with `conclusion=failure` (unchanged, job-less) and one `event=workflow_dispatch` with `conclusion=success`. Confirm the dispatched run has jobs:

```bash
gh api repos/blinkbitcoin/shared-workflows/actions/runs/<workflow_dispatch run id>/jobs -q '.jobs[] | "\(.name): \(.conclusion)"'
```

Expected: `Check: success`, `Parity: success` (`PR title` absent — it is skipped on dispatch, and skipped jobs still appear; either `skipped` or absent is fine).

When both packages release in one push there are two release branches; check that **each** got exactly one `workflow_dispatch` run. A second push that updates the same release PR dispatches again and, with `cancel-in-progress` on non-main refs, cancels the previous dispatched run for that branch: a `cancelled` run in the list is expected there, not a regression.

- [ ] **Step 3: Record the evidence on the PR**

```bash
gh pr comment <PR number> --body "Verified on the release PR after merge: workflow_dispatch run <id> on the release branch, Check and Parity green; the pull_request run <id> is the known job-less one and stays until the RELEASE_TAGGER App is set up (#39)."
```

If the dispatched run is missing: open the `Release` run for the merge on main, job `Release PR`, step `Run CI on the release PR`. A `skipped` step means `prs_created` was not `'true'` (no PR was created or updated by that push; wait for the next push that changes the release PR). A failed step prints the script's `::error::` line; the two likely causes are a missing `actions: write` (Task 3 Step 3) and an unexpected `prs` output shape (paste `PRS_JSON` from the step log into `test/dispatch-release-pr-ci.bats` as a new case and fix the `jq` path).

---

## Self-review

- **Coverage:** trigger (Task 1), script with error paths (Task 2), wiring, permission and docs (Task 3), on-GitHub verification with a recovery path (Task 4). The red run's removal is explicitly out of scope and left to the App step already in `self-release.yml`.
- **Placeholders:** none; every step has its content.
- **Consistency:** the script name `scripts/self/dispatch-release-pr-ci.sh`, its env contract (`PR_JSON`, `GH_TOKEN`, `GH_REPO`) and the step name "Run CI on the release PR" are identical across Tasks 2, 3 and 4. The test file `test/self-workflows.bats` is created in Task 1 and appended to in Task 3.
