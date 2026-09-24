# `check-security.yml` Implementation Plan (Stage 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the reusable `check-security.yml` workflow that runs the consumer's
security scanners in CI — one job per scanner so a red run names the scanner, and
one `verdict` job that merges their SARIF, uploads it to code scanning, writes
the run summary and applies the threshold. The scanners, the settings resolver
and the verdict itself already exist in the consumer (Stage 1); this stage adds
only what exists in CI.

**Architecture:** Five jobs. `config` runs the consumer's own `config.mjs` and
publishes the resolved policy as job outputs, because a job-level `if:` cannot
read a file. `deps`, `code` and `policy` each run one of the consumer's runners
through a thin shared bridge and upload its SARIF as an artifact. `verdict`
downloads all of them, runs the consumer's `verdict.mjs`, writes the step
summary, and — as the only job in the workflow with `security-events: write` —
uploads the SARIF to code scanning. Shared-workflows carries no scanner, no
merge and no fallback: four small bash bridges, and the YAML around them.

**Tech Stack:** GitHub Actions reusable workflow, bash (shellcheck strict), bats,
`yq` 4.53.6, `actions/checkout@v7`, `actions/upload-artifact@v7`,
`actions/download-artifact@v8`, `github/codeql-action/upload-sarif@v4`.

**Spec:** `/Users/jonas/Dev/blink/react-native-mobile-template-security/docs/superpowers/specs/2026-09-24-security-scanning-design.md`

**Stage 1 (already merged in the template):** `scripts/security/config.mjs`,
`sarif.mjs`, `verdict.mjs`, `lib/common.sh`, `deps.sh`, `code.sh`, `policy.sh`,
`local.sh`, `security-policy.json`, the `check-security*` make targets and
`docs/security.md`.

---

## What Stage 2 is not

State this out loud in the pull request body, because the last plan in this
family shipped documentation describing unbuilt work as present:

- **The template's call sites are Stage 3 and cannot merge until `v0` carries
  this file.** A `uses:` of a workflow file that does not exist on the pinned
  ref is a `startup_failure` for the whole run — on `main` too — which would
  also red the template's internal build gate. The order is: this pull request
  merges, shared-workflows releases, `v0` moves, then the template's callers.
  Watch the template's next CD / Internal run after the release, because no gate
  in this repository can execute its own reusable workflows.
- **Only three scanner jobs exist in Stage 2:** `deps`, `code` and `policy`.
  Those are the only runners Stage 1 built. `sbom`, `bundle`, `mobile`,
  `binaries`, `review` and `openant` appear in `security-policy.json`'s defaults
  and in `verdict.mjs`'s `ENGINE_OF`, but there is no `scripts/security/sbom.sh`
  and no `scripts/security/binaries.sh` anywhere. Declaring jobs for them now
  would make every consumer fail loudly on a runner that does not exist — the
  contract in Task 2 is designed to do exactly that, correctly, and the fix is
  to not declare the job until its runner ships. Each later stage adds its
  runner in the template **and** its job here, in that order.
- **No docs-only classifier.** `check-code.yml` and `check-codeql.yml` each run
  a `changes` job; this workflow does not. The caller already has
  `needs.checks.outputs.docs-only` from `check-code.yml`, and a second
  classifier would be a second rule that drifts. The caller gates; this workflow
  is gated.
- **No release-tier jobs, no LLM jobs, no `build-env`.** No job here takes an
  API key, so there is nothing for `build-env` to carry and no reason for this
  workflow to declare it. ADR 0021 and an existing structural test forbid LLM
  credentials in a CD lane; nothing in Stage 2 goes near one.

## Global Constraints

- **Every task ends with `make check` green** — not `bats test/workflow-shape.bats`,
  not `make test`. `make check` is `shellcheck actionlint zizmor test
  test-package check-versions tool-versions spell secrets`, and three of Stage 1's
  tasks were "verified" with a narrower gate while the full one was red. The last
  step of every task below runs `mise exec -- make check` and the task is not
  done until it prints nothing red.
- **Every assertion in a `.bats` body ends in `|| fail "..."` on the same
  logical line.** `test/assertions-enforced.bats` fails the suite otherwise, and
  a bare `[[ ]]` or `! cmd` is silently unenforceable on bash 3.2 (macOS) anyway.
  `[ ... ]` is a simple command and is exempt from the guard, but write `|| fail`
  there too wherever the message helps.
- **Every `run:` step in a workflow is a single `bash …` line.**
  `test/workflow-shape.bats` enforces it. Nothing in this workflow may be inline
  shell; anything that needs logic becomes a script under `scripts/security/`
  in *this* repository, and every such script must be executed by a bats test
  (`test/script-coverage.bats`).
- **No hardcoded repository owner or name in any workflow expression or shell
  script.** Use `github.repository`, `job.workflow_repository` and
  `job.workflow_sha`. The one place a literal `blinkbitcoin/shared-workflows`
  appears is the `uses:` line of a caller example and of the fixture caller,
  where it is the address of the workflow being called and every existing
  fixture spells it the same way.
- **Marked counts in `README.md` are assertions.** `test/docs-facts.bats`
  compares `<!--count:reusable-workflows-->`, `workflows`, `scripts`,
  `shell-scripts`, `bats-files` and `tests` against the tree. `git ls-files` is
  the source, so **stage the new files before reading a count**, and read every
  count from the tool rather than by arithmetic.
- **Values live in the consumer's file; workflow inputs are booleans only.**
  `severity` and `failOn` are read out of `security-policy.json` by the
  consumer's own resolver and are never workflow inputs. An input may narrow
  what the consumer asked for and never widen it.
- **`typos` reads workflow input descriptions, guide prose and bats messages.**
  It is part of `make check`, and it rejects more than obvious slips: an
  all-capitals "and" given a past-tense suffix is read as a misspelling of
  "dead", and the adjective built from "parse" with a doubled vowel is read as
  a misspelling too. Both were written into an earlier draft of this plan and
  had to go. Rephrase rather than adding an entry to `typos.toml`.
- **Commit scopes** come from this repository's commitlint enum. Stage 2 uses
  `feat(ci)` for the workflow and its scripts, `docs` for the guide and README.
  A wrong scope is rejected silently under a pipe — always confirm with
  `git log -1 --format='%h %s'` after committing.
- **Consumer-visible behaviour is `feat`/`fix`, never `docs`.** shared-workflows
  only releases on `feat`, `fix` and `perf`; a new reusable workflow shipped
  under a `docs` scope would produce no version pull request and `v0` would
  never carry it.

## The three decisions this plan makes

**1. The settings seam: a `config` job, *and* boolean inputs, combined with a logical and.**
A job-level `if:` cannot read a file, so the workflow cannot gate on
`security-policy.json` directly. It also must not re-implement the resolution
order — that is `config.mjs`, and two implementations of one resolution order
drift. So one job runs the consumer's own resolver once and publishes the answer
as job outputs the other jobs' `if:` expressions can read. The workflow's own
inputs stay booleans that express what a *tier* can do (a pull request has no
binaries to scan), and the effective setting is
`inputs.<job> && needs.config.outputs.<job> == 'true' && needs.config.outputs.enabled == 'true'`
— an AND, so a caller may narrow and never widen. The runners also self-skip via
`sec_enabled`, which makes the `if:` redundant for correctness; it is there so a
turned-off scanner costs no runner and so the run graph tells the truth about
what ran.

**2. Fork behaviour: block the same, report elsewhere, and say so.**
A pull request from a fork gets a read-only `GITHUB_TOKEN` whatever the
`permissions:` block asks for, so `upload-sarif` cannot work. The verdict still
runs, still applies the threshold and still fails the run on a blocking finding —
the gate is not weaker on a fork, only its reporting destination is. The upload
step is guarded, and a second step runs on exactly the complementary condition
and prints a `::warning::` plus a line in the run summary naming the reason. The
same treatment covers `sarif-upload: false`. Silence is the one outcome that is
not allowed.

**3. A missing consumer script fails loudly, from shared, by name.**
Every scanner job goes through `scripts/security/run-job.sh <job>` in this
repository, which refuses to run before it has found `scripts/security/<job>.sh`
in the consumer, and dies with `die_fix` naming the file, the three ways to
switch the job off, and the guide anchor. It then insists the runner left a
non-empty `<job>.sarif`: a runner that exits 0 without reporting would reach the
verdict as nothing at all, and "no findings from a job that never reported" is
precisely the silence the adapter contract forbids. Shared ships no fallback
runner and no `.mjs` under `scripts/security/` at all — Task 2's test asserts
that, so a well-meaning "let me just add a default scanner here" fails.

## How this plan was checked

Each task's tests were executed mentally against that task's own code before the
task was written down — the check that would have caught Stage 1's worst defect,
where a task's tests contradicted the code in the same task. The specific traces
run, and what they caught:

- `settings.sh` against its four cases: the happy path writes six `key=value`
  lines into `$GITHUB_OUTPUT`; the missing-resolver case reaches `die_fix`
  before `node` is called; the empty-output case is a real failure mode, not a
  hypothetical — `config.mjs` guards its CLI with `import.meta.main`, which is
  `undefined` before Node 24, so an older `node` runs the file, prints nothing
  and exits 0. That is why the `config` job runs the `setup` action (the
  consumer's `.mise.toml` Node pin) instead of the runner's own node, unlike
  `check-code.yml`'s `contract` job, and why the script treats empty output as
  fatal. Reading it as "nothing enabled" would switch the entire gate off in
  silence.
- `run-job.sh` against a runner that writes a SARIF, one that writes none, one
  that exits non-zero, and a missing one — the middle case is the one that
  needs `[ -s ]` rather than `[ -f ]`.
- `verdict.sh` against a merger that exits 1: `code=0; report="$(node …)" || code=$?`
  is the form that survives `set -e`; the earlier draft used
  `count="$(find … | grep -c .)"` and, under `set -o pipefail`, an empty match
  makes the assignment fail and `count` empty, so `[ "" -gt 0 ]` errors instead
  of reporting. It is `wc -l` now, which always exits 0.
- Every new bats assertion against the yq expression beside it, on the YAML this
  plan actually writes: `install: 'false'` is quoted on purpose, because
  unquoted `install: false` makes `yq` return a boolean and the assertion
  `.with.install != "false"` then fails on correct YAML.
- Every new `.bats` line against `test/assertions-enforced.bats`'s regex: the one
  statement that starts with `!` carries `|| fail` on the same line.
- The new guide section and fixture caller against `test/consumer-contract.bats`:
  the caller-example cases index `ci:1 ci-web:2 ci-pr-closed:3 ci-pr-title:4
  ci-codeql:6`, so the new ```yaml block is appended *after* the `check-codeql.yml`
  section and the existing indices are untouched.

---

### Task 1: The four bridges between the workflow and the consumer's scripts

**Files:**
- Create: `scripts/security/settings.sh`
- Create: `scripts/security/run-job.sh`
- Create: `scripts/security/verdict.sh`
- Create: `scripts/security/sarif-upload-skipped.sh`
- Create: `test/security-bridge.bats`
- Modify: `README.md` (the `scripts`, `shell-scripts`, `bats-files` and `tests` counts)

**Interfaces produced (Task 2 consumes all four):**
- `bash scripts/security/settings.sh` — resolves the consumer's policy and writes
  `enabled`, `severity`, `fail-on` and one boolean per job name to
  `$GITHUB_OUTPUT`.
- `bash scripts/security/run-job.sh JOB` — runs the consumer's
  `scripts/security/<JOB>.sh` and guarantees `.security/<JOB>.sarif` exists and
  is non-empty, or fails.
- `bash scripts/security/verdict.sh` — runs the consumer's `verdict.mjs` over
  `.security/`, echoes the report, appends it to `$GITHUB_STEP_SUMMARY`, and
  exits with the verdict's own exit code.
- `bash scripts/security/sarif-upload-skipped.sh REASON` — a `::warning::` and a
  summary line saying the findings did not reach code scanning, and why.

All four locate the consumer through `consumer_root()` from
`scripts/lib/common.sh`, so `working-directory` is honoured without any of them
knowing it exists.

- [ ] **Step 1: Write the failing tests**

Create `test/security-bridge.bats`:

```bash
#!/usr/bin/env bats
# The four bridges check-security.yml runs. Everything they bridge *to* - the
# resolver, the runners, the merge - lives in the consumer, and none of it is
# reimplemented here. What is tested is the seam: that a consumer missing one of
# those files fails loudly and by name, and that a runner which reports nothing
# can never be read as a runner which found nothing.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# A throwaway consumer checkout. $1 names the directory; the script's body is
# read from stdin so a test can hand it any behaviour, including no output at
# all. Nothing is copied from the template: these are stand-ins for the
# consumer's files, not second copies of them.
consumer_with() {
  local dir="$BATS_TEST_TMPDIR/$1" file="$2"
  mkdir -p "$dir/$(dirname "$file")"
  cat > "$dir/$file"
  printf '%s' "$dir"
}

@test "settings.sh publishes enabled, severity, failOn and one output per job" {
  local consumer
  consumer="$(consumer_with on scripts/security/config.mjs <<'EOF'
console.log(
  JSON.stringify({
    enabled: true,
    jobs: { deps: true, code: false, policy: true },
    severity: 'high',
    failOn: ['deterministic'],
  }),
);
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  local written
  written="$(cat "$GITHUB_OUTPUT")"
  local want
  for want in 'enabled=true' 'severity=high' 'fail-on=deterministic' 'deps=true' 'code=false' 'policy=true'; do
    grep -qxF "$want" <<<"$written" || fail "no '$want' among the published outputs: $written"
  done
}

@test "settings.sh fails by name when the consumer ships no resolver" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/config.mjs' || fail "the error does not name the missing file: $output"
  contains "$output" '::error::' || fail "the failure is not a GitHub annotation: $output"
}

# The failure mode worth a test of its own: config.mjs guards its CLI entry with
# `import.meta.main`, undefined before Node 24. An older node runs the file,
# prints nothing, exits 0 - and empty output read as "no jobs enabled" would
# disable the whole gate in silence.
@test "settings.sh treats a resolver that prints nothing as fatal, not as all-off" {
  local consumer
  consumer="$(consumer_with silent scripts/security/config.mjs <<'EOF'
// prints nothing, exits 0
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "an empty resolver read as a valid answer: $output"
  contains "$output" 'Node 24' || fail "the error does not name the cause: $output"
}

@test "settings.sh rejects output that is not the settings object" {
  local consumer
  consumer="$(consumer_with broken scripts/security/config.mjs <<'EOF'
console.log('not the settings object at all');
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "unreadable output was read as a valid answer: $output"
  contains "$output" 'not the settings object' || fail "the error does not say what was wrong: $output"
}

@test "run-job.sh runs the consumer's runner and reports where the SARIF landed" {
  local consumer
  consumer="$(consumer_with good scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${SECURITY_DIR:-.security}"
mkdir -p "$out"
printf '{"version":"2.1.0","runs":[]}' > "$out/deps.sarif"
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 0 ] || fail "run-job.sh failed: $output"
  [ -s "$consumer/.security/deps.sarif" ] || fail "no SARIF at $consumer/.security/deps.sarif"
}

@test "run-job.sh fails by name when the consumer ships no runner for the job" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/norunner"
  mkdir -p "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" code
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/code.sh' || fail "the error does not name the missing runner: $output"
  contains "$output" 'security-policy.json' || fail "the error does not say how to switch the job off: $output"
}

# A runner that exits 0 without writing its SARIF would reach the verdict as
# nothing at all, and the verdict cannot tell "found nothing" from "reported
# nothing". So the bridge insists on the file.
@test "run-job.sh fails when a runner exits 0 having reported nothing" {
  local consumer
  consumer="$(consumer_with quiet scripts/security/policy.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" policy
  [ "$status" -eq 1 ] || fail "a silent runner passed: $output"
  contains "$output" 'policy.sarif' || fail "the error does not name the SARIF that is missing: $output"
}

@test "run-job.sh hands back a crashing runner's exit code" {
  local consumer
  consumer="$(consumer_with crash scripts/security/deps.sh <<'EOF'
#!/usr/bin/env bash
echo "osv-scanner: bad config" >&2
exit 3
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/run-job.sh" deps
  [ "$status" -eq 3 ] || fail "expected the runner's own exit code 3, got $status: $output"
}

@test "verdict.sh runs the consumer's merge, prints it, and keeps its exit code" {
  local consumer
  consumer="$(consumer_with fails scripts/security/verdict.mjs <<'EOF'
console.log('deps: 1 finding(s), highest high');
console.log('security: fail, highest high, 1 finding(s), 0 suppressed, 0 job(s) skipped');
process.exit(1);
EOF
)"
  mkdir -p "$consumer/.security"
  printf '{"version":"2.1.0","runs":[]}' > "$consumer/.security/deps.sarif"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "the verdict's exit code was not handed back: $status / $output"
  contains "$output" 'security: fail' || fail "the report never reached the log: $output"
  grep -q 'security: fail' "$BATS_TEST_TMPDIR/summary.md" || fail "the report never reached the run summary"
  grep -q '^## Security' "$BATS_TEST_TMPDIR/summary.md" || fail "the summary block has no heading"
}

@test "verdict.sh refuses to report a clean run when no scanner reported at all" {
  local consumer
  consumer="$(consumer_with empty scripts/security/verdict.mjs <<'EOF'
console.log('security: pass');
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "an empty .security/ produced a verdict: $output"
  contains "$output" 'no SARIF files' || fail "the error does not say what was missing: $output"
}

@test "verdict.sh fails by name when the consumer ships no merge" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/nomerge"
  mkdir -p "$GITHUB_WORKSPACE/.security"
  printf '{}' > "$GITHUB_WORKSPACE/.security/deps.sarif"
  run bash "$REPO_ROOT/scripts/security/verdict.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/verdict.mjs' || fail "the error does not name the missing file: $output"
}

@test "sarif-upload-skipped.sh warns in the log and in the summary, with the reason" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh" "this run is a pull request from a fork"
  [ "$status" -eq 0 ] || fail "$output"
  contains "$output" '::warning::' || fail "a missing upload passed without an annotation: $output"
  contains "$output" 'pull request from a fork' || fail "the reason is missing: $output"
  grep -q 'not.*uploaded to code scanning' "$BATS_TEST_TMPDIR/summary.md" \
    || fail "the run summary does not say the findings never reached code scanning"
  grep -q 'still applied the threshold' "$BATS_TEST_TMPDIR/summary.md" \
    || fail "the run summary does not say the gate still ran"
}

@test "sarif-upload-skipped.sh refuses to run without a reason" {
  run bash "$REPO_ROOT/scripts/security/sarif-upload-skipped.sh"
  [ "$status" -ne 0 ] || fail "a reasonless notice is exactly the silence this step exists to prevent: $output"
}
```

- [ ] **Step 2: Run the tests and watch them fail**

```bash
mise exec -- bats test/security-bridge.bats
```

Expected: 14 failures, each `No such file or directory` for the script under
test.

- [ ] **Step 3: Write `scripts/security/settings.sh`**

```bash
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
```

Every key of `settings.jobs` is published, not only the three this workflow has
jobs for. The extra outputs cost nothing, and a later stage that adds an `sbom`
job needs no change here.

- [ ] **Step 4: Write `scripts/security/run-job.sh`**

```bash
#!/usr/bin/env bash
# Run one of the consumer's security runners, and insist it reported.
#
# Usage: run-job.sh JOB
#
# Shared ships no fallback runner. A job that is switched on but whose
# scripts/security/<job>.sh does not exist fails here, by name - it never skips
# quietly, because a pipeline that scans nothing while reporting green is worse
# than one that is red. When a second, non-template consumer appears, the shared
# subset moves into @blinkbitcoin/dev-config; a duplicate here would serve
# nobody today.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

job="${1:?usage: run-job.sh JOB}"
root="$(consumer_root)"
cd "$root"

runner="scripts/security/$job.sh"
[ -f "$runner" ] || die_fix \
  "the $job scanner is switched on, but this repository has no $runner" \
  "add $runner, or set \"jobs\": { \"$job\": { \"enabled\": false } } in security-policy.json, or pass $job: false to check-security.yml" \
  "check-securityyml"

out="${SECURITY_DIR:-.security}"
mkdir -p "$out"
# A finding never fails a runner: the runner exits 0 with findings, and only the
# verdict fails on them. A non-zero exit here is a crash - a missing binary
# under CI, a bad config, output that is not SARIF - and errexit hands its
# status straight back, so the run names the scanner that died.
bash "$runner"

sarif="$out/$job.sarif"
# -s, not -f: a zero-byte file is the same silence as no file. A runner that
# exits 0 without reporting would reach the verdict as nothing at all, and the
# verdict cannot tell "found nothing" from "reported nothing".
[ -s "$sarif" ] || die "$runner exited 0 but left no $sarif. Every runner writes exactly one SARIF, a skipped one included (scripts/security/lib/common.sh: sec_skip)"
log "$job: $sarif"
```

- [ ] **Step 5: Write `scripts/security/verdict.sh`**

```bash
#!/usr/bin/env bash
# Merge the scanners' SARIF into one verdict, and put that verdict where it will
# be read: the step log and the run summary.
#
# The merge, the threshold and the exit code are the consumer's verdict.mjs -
# the same file `make check-security` runs - so a green laptop and a green
# pipeline are the same claim. This wrapper decides only where the answer is
# written, and hands the exit code back untouched.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

root="$(consumer_root)"
cd "$root"

merger='scripts/security/verdict.mjs'
[ -f "$merger" ] || die_fix \
  "check-security.yml reached its verdict job, but this repository has no $merger" \
  "add scripts/security/verdict.mjs as the template ships it, or stop calling check-security.yml" \
  "check-securityyml"

out="${SECURITY_DIR:-.security}"
count=0
if [ -d "$out" ]; then
  # wc -l, not `grep -c .`: under `set -o pipefail` an empty match makes the
  # whole substitution fail and leaves `count` empty, and `[ "" -gt 0 ]` then
  # errors instead of reporting. wc always exits 0.
  count="$(find "$out" -maxdepth 1 -type f -name '*.sarif' | wc -l | tr -d ' ')"
fi
# No SARIF at all means every scanner skipped or died. A clean verdict derived
# from nothing is the one outcome this gate must never produce, so it is a
# failure with a message that points at the jobs above rather than at this one.
[ "$count" -gt 0 ] || die "no SARIF files in $out: every scanner job was switched off or failed. Read the scanner jobs above; do not read this run as clean. To turn the gate off, set \"enabled\": false in security-policy.json"

code=0
report="$(node "$merger" "$out" 2>&1)" || code=$?
printf '%s\n' "$report"
{
  printf '## Security\n\n'
  printf '```\n%s\n```\n' "$report"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
exit "$code"
```

- [ ] **Step 6: Write `scripts/security/sarif-upload-skipped.sh`**

```bash
#!/usr/bin/env bash
# Say out loud that the findings did not reach code scanning.
#
# Usage: sarif-upload-skipped.sh REASON
#
# A pull request from a fork gets a read-only GITHUB_TOKEN whatever the
# workflow's permissions block requests, so the SARIF upload cannot happen. The
# verdict still ran and still blocked or passed on its own findings - the gate is
# not weaker on a fork, only its reporting destination is - and a reader has to
# be told that, or an empty Security tab reads as "scanned, nothing found".
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

reason="${1:?usage: sarif-upload-skipped.sh REASON}"
printf '::warning::Security findings were not uploaded to code scanning: %s. The verdict still applied the threshold - read the job summary and the Verdict step for the findings.\n' "$reason"
{
  printf '\n> Findings were **not** uploaded to code scanning: %s.\n' "$reason"
  printf '> The verdict above still applied the threshold; the findings are in this summary and in the job log.\n'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
```

- [ ] **Step 7: Run the tests and watch them pass**

```bash
mise exec -- bats test/security-bridge.bats
```

Expected: 14 passing.

- [ ] **Step 8: Prove the scripts are counted as covered**

```bash
mise exec -- bats test/script-coverage.bats
```

Expected: passing. `test/script-coverage.bats` counts a script as covered only
when a test *executes* it; each of the four is invoked as
`bash "$REPO_ROOT/scripts/security/<name>.sh"`, which the resolver's `RUNNERS`
pattern matches. If one is reported uncovered, add a case that runs it — never
an `ALLOWED` entry, since all four are runnable from bats.

- [ ] **Step 9: Update the marked counts in README.md**

Stage first, because `test/docs-facts.bats` derives every count from
`git ls-files`:

```bash
git add scripts/security test/security-bridge.bats
mise exec -- bash -c 'git ls-files "scripts/**/*.sh" | wc -l'
mise exec -- bash -c 'git ls-files "scripts/**/*.sh" "scripts/**/*.mjs" | wc -l'
mise exec -- bash -c 'git ls-files "test/*.bats" | wc -l'
mise exec -- bats --count test/
```

Write each printed number into `README.md`, replacing the digits between the
markers and nothing else:

- line 12: `<!--count:scripts-->…<!--/count-->` and `<!--count:tests-->…<!--/count-->`
- line 23: `<!--count:shell-scripts-->…<!--/count-->`
- line 196: `<!--count:bats-files-->…<!--/count-->` and `<!--count:tests-->…<!--/count-->`

Do not compute these by arithmetic; read them from the commands above.

- [ ] **Step 10: Run the full gate**

```bash
mise exec -- make check
```

Expected: green — `shellcheck`, `actionlint`, `zizmor`, the whole bats suite,
`test-package`, `check-versions`, `tool-versions`, `spell` and `secrets`. If
`shellcheck` objects to `source "$(dirname "$0")/../lib/common.sh"`, do not add
a disable directive: `.shellcheckrc` already sets `external-sources=true` and
`source-path=SCRIPTDIR`, and `scripts/checks/run-script.sh` uses the identical
line, so an error there means the path is genuinely wrong.

- [ ] **Step 11: Commit**

```bash
git add scripts/security test/security-bridge.bats README.md
git commit -m "feat(ci): bridge CI to the consumer's security scripts

Four small scripts: resolve the consumer's policy into job outputs, run one of
its runners and insist it reported, run its verdict into the step summary, and
say out loud when findings could not reach code scanning.

Shared ships no resolver, no runner and no merge. A consumer missing one fails
by name rather than skipping quietly.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 2: `check-security.yml`

**Files:**
- Create: `.github/workflows/check-security.yml`
- Modify: `test/workflow-shape.bats` (add `check-security` to the published list; five new cases)
- Modify: `README.md` (the `reusable-workflows`, `workflows` and `tests` counts)

**Interfaces produced (Task 3 consumes):** the ten `workflow_call` inputs
(`repository`, `ref`, `working-directory`, `linux-runner`, `macos-runner`,
`native-cache-version`, `deps`, `code`, `policy`, `sarif-upload`), the optional
`consumer-token` secret, and the permission set a caller must grant
(`contents: read`, `actions: read`, `security-events: write`).

- [ ] **Step 1: Write the failing tests**

In `test/workflow-shape.bats`, add `check-security` to the published-workflow
list so a rename or a deletion is caught. Replace:

```bash
  for w in check-code check-unit check-e2e build-web publish-badges pr-closed pr-title check-codeql \
    build-prepare build-ios build-android \
    publish-store publish-github-release publish-ota pr-release-notes; do
```

with:

```bash
  for w in check-code check-unit check-e2e build-web publish-badges pr-closed pr-title check-codeql \
    check-security build-prepare build-ios build-android \
    publish-store publish-github-release publish-ota pr-release-notes; do
```

Then append these five cases to the end of `test/workflow-shape.bats`:

```bash
# ---------------------------------------------------------------------------
# check-security.yml - the second workflow in the family that writes to code
# scanning, and the first whose job graph is decided by a file in the consumer.
# ---------------------------------------------------------------------------

# security-events: write is the whole reason a caller has to grant anything at
# all here, and a called workflow can only ever narrow the caller's token - so
# an escalation that spreads to a scanner job would make every caller grant more
# than the one job that needs it. Naming `permissions:` also resets the unnamed
# scopes to none, which is why contents: read is re-declared rather than assumed.
@test "check-security.yml escalates permissions only on its verdict job" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  [ "$(yq -r '.jobs.verdict.permissions.contents' "$f")" = "read" ] \
    || fail "verdict does not re-declare contents: read, so its own checkouts would lose it"
  [ "$(yq -r '.jobs.verdict.permissions.actions' "$f")" = "read" ] \
    || fail "verdict does not declare actions: read, which the SARIF upload needs"
  [ "$(yq -r '.jobs.verdict.permissions."security-events"' "$f")" = "write" ] \
    || fail "verdict does not declare security-events: write"
  [ "$(yq -r '.jobs.verdict.permissions | keys | length' "$f")" -eq 3 ] \
    || fail "verdict asks for more than three scopes: $(yq -r '.jobs.verdict.permissions' "$f")"
  escalating="$(yq -r '[.jobs | to_entries[] | select(.value.permissions) | .key] | join(",")' "$f")"
  [ "$escalating" = "verdict" ] \
    || fail "jobs declaring their own permissions in check-security.yml: $escalating - only verdict may"
}

# A job-level `if:` cannot read a file, so the consumer's security-policy.json
# reaches the graph only through the config job's outputs. The effective setting
# is the AND of the caller's input and the consumer's policy: a caller may
# narrow (a pull request has no binaries to scan) and may never widen.
@test "check-security.yml's scanner jobs are the AND of the caller's input and the consumer's policy" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  for job in deps code policy; do
    cond="$(yq -r ".jobs.\"$job\".if" "$f")"
    contains "$cond" "inputs.$job" || fail "the $job job ignores its own input: $cond"
    contains "$cond" "needs.config.outputs.$job == 'true'" \
      || fail "the $job job ignores the consumer's policy: $cond"
    contains "$cond" "needs.config.outputs.enabled == 'true'" \
      || fail "the $job job ignores the master switch: $cond"
    needs="$(yq -r ".jobs.\"$job\".needs" "$f")"
    [ "$needs" = "config" ] || fail "the $job job needs '$needs', expected config"
  done
  # !cancelled(), not success(): a scanner that was switched off, or one that
  # crashed, must still reach the verdict. A crash keeps the run red on its own
  # job; the verdict's business is to say what was and was not scanned.
  vcond="$(yq -r '.jobs.verdict.if' "$f")"
  contains "$vcond" '!cancelled()' || fail "the verdict never runs after a skipped or failed scanner: $vcond"
  contains "$vcond" "needs.config.outputs.enabled == 'true'" \
    || fail "the verdict ignores the master switch: $vcond"
  vneeds="$(yq -r '.jobs.verdict.needs | join(",")' "$f")"
  [ "$vneeds" = "config,deps,code,policy" ] || fail "verdict needs '$vneeds'"
}

# The consumer owns every scanner, the merge and the verdict. Shared owns the
# job graph and nothing else. A fallback runner here would serve only a consumer
# not generated from the template, and no such consumer exists - "a baseline
# with one consumer is not a baseline".
@test "check-security.yml runs the consumer's scripts and shares no runner of its own" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  for job in deps code policy; do
    line="$(yq -r ".jobs.\"$job\".steps[] | select(.id == \"scan\") | .run" "$f")"
    contains "$line" 'scripts/security/run-job.sh' \
      || fail "the $job job does not go through run-job.sh, which is what fails loudly on a missing runner: $line"
  done
  ! ls "$REPO_ROOT"/scripts/security/*.mjs >/dev/null 2>&1 \
    || fail "shared-workflows has grown its own security modules; the resolver, the scanners and the merge live in the consumer"
  vline="$(yq -r '.jobs.verdict.steps[] | select(.id == "verdict") | .run' "$f")"
  contains "$vline" 'scripts/security/verdict.sh' || fail "the verdict step does not go through verdict.sh: $vline"
}

# A fork's GITHUB_TOKEN is read-only whatever a permissions block asks for, so
# upload-sarif cannot work there. The gate is not weaker on a fork - the verdict
# still applies the threshold - but the reporting destination is missing, and
# that has to be said rather than left as an empty Security tab.
@test "check-security.yml uploads SARIF only when it can, and says so when it cannot" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  upload="$(yq -r '.jobs.verdict.steps[] | select((.uses // "") | test("upload-sarif")) | .if' "$f")"
  [ -n "$upload" ] || fail "check-security.yml has no upload-sarif step"
  contains "$upload" "github.event.pull_request.head.repo.full_name == github.repository" \
    || fail "the upload is not guarded against a fork pull request: $upload"
  contains "$upload" "github.event_name != 'pull_request'" \
    || fail "the fork guard would also block a push and a dispatch, where both operands are empty: $upload"
  contains "$upload" 'hashFiles' \
    || fail "the upload is not guarded on a SARIF actually existing, and upload-sarif dies on an empty directory: $upload"
  notes="$(yq -r '[.jobs.verdict.steps[] | select((.run // "") | test("sarif-upload-skipped.sh"))] | length' "$f")"
  [ "$notes" -eq 2 ] \
    || fail "expected two steps explaining a missing upload (a fork, and sarif-upload: false), found $notes"
}

# One artifact per scanner, each carrying a file named after its own job. The
# release's build-info taught this family what merge-multiple does to two
# artifacts carrying the same filename: the winner is a coin toss. Here the
# filenames differ by construction, which is the only reason merge-multiple is
# safe - so both halves are pinned.
@test "each scanner's SARIF travels under its own artifact name and its own filename" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  names="$(yq -r '[.jobs[].steps[]? | select((.uses // "") | test("upload-artifact")) | .with.name] | join("\n")' "$f")"
  [ "$(grep -c . <<<"$names")" -eq 3 ] || fail "expected three SARIF uploads, got: $names"
  [ "$(sort -u <<<"$names" | grep -c .)" -eq 3 ] || fail "two scanner jobs upload under one artifact name: $names"
  paths="$(yq -r '[.jobs[].steps[]? | select((.uses // "") | test("upload-artifact")) | .with.path] | join("\n")' "$f")"
  for job in deps code policy; do
    contains "$paths" "/.security/$job.sarif" || fail "no upload of $job.sarif: $paths"
  done
  merge="$(yq -r '[.jobs.verdict.steps[] | select((.uses // "") | test("download-artifact"))][0].with."merge-multiple"' "$f")"
  [ "$merge" = "true" ] || fail "the verdict does not merge the scanner artifacts into one directory: $merge"
  # These jobs read source, a lockfile and a workspace file. None of them reads
  # node_modules, and a pnpm install in each is minutes added to every consumer's
  # pull request for nothing. Quoted 'false' on purpose: unquoted, yq returns a
  # boolean and this assertion fails on correct YAML.
  setups="$(yq -r '[.jobs[].steps[]? | select((.uses // "") | test("workflows/.github/actions/setup"))] | length' "$f")"
  [ "$setups" -eq 5 ] || fail "expected one Setup step per job, found $setups"
  installing="$(yq -r '[.jobs[].steps[]? | select((.uses // "") | test("workflows/.github/actions/setup")) | select(.with.install != "false")] | length' "$f")"
  [ "$installing" -eq 0 ] || fail "$installing Setup step(s) run pnpm install, which no job here needs"
}
```

- [ ] **Step 2: Run the tests and watch them fail**

```bash
mise exec -- bats test/workflow-shape.bats
```

Expected: six failures — the published-list case plus the five new ones, all
because `.github/workflows/check-security.yml` does not exist.

- [ ] **Step 3: Write the workflow**

Create `.github/workflows/check-security.yml`:

```yaml
name: Security
# The consumer's security scanners, one job each so a red run names the scanner,
# and one verdict that merges their SARIF and applies the threshold.
#
# Every scanner, the settings resolver and the merge live in the CONSUMER, under
# scripts/security/. `make check-security` runs the same files, so a green
# laptop and a green pipeline are the same claim. This workflow owns only what
# exists in CI: the job graph, the permissions, the artifact passing, the upload
# to code scanning and the step summary. It carries no fallback runner - a job
# that is switched on but whose runner is missing fails loudly, by name.
on:
  workflow_call:
    inputs:
      repository:
        description: Consumer repository to check out (defaults to the caller's repository)
        type: string
        default: ''
      ref:
        description: Consumer ref to check out (empty lets actions/checkout resolve the correct ref, including PR merge refs)
        type: string
        default: ''
      working-directory:
        description: Consumer directory relative to GITHUB_WORKSPACE
        type: string
        default: '.'
      linux-runner:
        description: Runner label for every job in this workflow
        type: string
        default: 'ubuntu-latest'
      macos-runner:
        description: Runner label for macOS jobs (unused by this workflow; carried for input-set consistency across the family)
        type: string
        default: 'macos-26'
      native-cache-version:
        description: Native cache key prefix (unused by this workflow; carried for input-set consistency across the family)
        type: string
        default: 'v1'
      deps:
        description: >-
          Allow the dependency scanner (the consumer's `check-security-deps`).
          A switch, not a setting: whether it actually runs is this AND the
          consumer's security-policy.json, so a caller may narrow and never widen.
        type: boolean
        default: true
      code:
        description: Allow the source scanner (the consumer's `check-security-code`); the effective setting is this and security-policy.json together
        type: boolean
        default: true
      policy:
        description: Allow the install-policy scanner (the consumer's `check-security-policy`); the effective setting is this and security-policy.json together
        type: boolean
        default: true
      sarif-upload:
        description: >-
          Upload the merged SARIF to code scanning. Off makes the run say so in
          the summary rather than go quiet; the verdict still applies the
          threshold either way.
        type: boolean
        default: true
    secrets:
      consumer-token:
        description: PAT with read access to a private consumer repository; falls back to the caller's github.token (works for a public consumer)
        required: false
permissions:
  contents: read
jobs:
  # A job-level `if:` cannot read a file, and security-policy.json is a file in
  # the consumer. So the policy is resolved once, here, by the consumer's own
  # config.mjs - not by a second implementation of the same resolution order -
  # and published as outputs the other jobs' `if:` expressions can read.
  config:
    name: Config
    runs-on: ${{ inputs.linux-runner }}
    timeout-minutes: 10
    outputs:
      enabled: ${{ steps.resolve.outputs.enabled }}
      deps: ${{ steps.resolve.outputs.deps }}
      code: ${{ steps.resolve.outputs.code }}
      policy: ${{ steps.resolve.outputs.policy }}
      severity: ${{ steps.resolve.outputs.severity }}
      fail-on: ${{ steps.resolve.outputs.fail-on }}
    steps:
      - name: Checkout consumer
        uses: actions/checkout@v7
        with:
          repository: ${{ inputs.repository || github.repository }}
          ref: ${{ inputs.ref }}
          token: ${{ secrets.consumer-token || github.token }}
      - name: Checkout shared-workflows
        uses: actions/checkout@v7
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .workflows
          persist-credentials: false
      # Setup here, unlike check-code.yml's contract job, which deliberately runs
      # on the runner image's own node. config.mjs guards its command-line entry
      # with `import.meta.main`, which is undefined before Node 24: an older node
      # would run the file, print nothing and exit 0, and empty output read as
      # "nothing enabled" would switch the whole gate off in silence. The
      # consumer's .mise.toml pin is what makes that impossible.
      #
      # install: 'false' - no job in this workflow reads node_modules. The
      # scanners read source, pnpm-lock.yaml and pnpm-workspace.yaml, and the
      # consumer's scripts/security/*.mjs are zero-dependency node. Quoted,
      # because the composite action's inputs are strings.
      - name: Setup
        uses: ./.workflows/.github/actions/setup
        with:
          working-directory: ${{ inputs.working-directory }}
          install: 'false'
      - name: Resolve the security policy
        id: resolve
        run: bash "$WORKFLOWS_DIR/scripts/security/settings.sh"
  deps:
    name: Dependencies
    needs: config
    # The AND of the caller's tier and the consumer's policy. A skipped job is
    # green, so a repository that has turned the gate off never holds up a
    # required check.
    if: ${{ inputs.deps && needs.config.outputs.enabled == 'true' && needs.config.outputs.deps == 'true' }}
    runs-on: ${{ inputs.linux-runner }}
    timeout-minutes: 20
    steps:
      - name: Checkout consumer
        uses: actions/checkout@v7
        with:
          repository: ${{ inputs.repository || github.repository }}
          ref: ${{ inputs.ref }}
          token: ${{ secrets.consumer-token || github.token }}
      - name: Checkout shared-workflows
        uses: actions/checkout@v7
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .workflows
          persist-credentials: false
      - name: Setup
        uses: ./.workflows/.github/actions/setup
        with:
          working-directory: ${{ inputs.working-directory }}
          install: 'false'
      - name: Scan dependencies
        id: scan
        env:
          SECURITY_JOB: deps
        run: bash "$WORKFLOWS_DIR/scripts/security/run-job.sh" "$SECURITY_JOB"
      # Same guard as check-e2e.yml's platform uploads: a failed scan has no
      # SARIF, and if-no-files-found: error would stack a second red step on top
      # of the real one. if-no-files-found stays `error` because a *successful*
      # scan with no SARIF is the silence run-job.sh already refuses.
      - name: Upload SARIF
        if: ${{ !cancelled() && steps.scan.conclusion != 'failure' }}
        uses: actions/upload-artifact@v7
        with:
          name: security-sarif-deps
          path: ${{ inputs.working-directory }}/.security/deps.sarif
          if-no-files-found: error
          retention-days: 7
  code:
    name: Code
    needs: config
    if: ${{ inputs.code && needs.config.outputs.enabled == 'true' && needs.config.outputs.code == 'true' }}
    runs-on: ${{ inputs.linux-runner }}
    timeout-minutes: 25
    steps:
      - name: Checkout consumer
        uses: actions/checkout@v7
        with:
          repository: ${{ inputs.repository || github.repository }}
          ref: ${{ inputs.ref }}
          token: ${{ secrets.consumer-token || github.token }}
      - name: Checkout shared-workflows
        uses: actions/checkout@v7
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .workflows
          persist-credentials: false
      - name: Setup
        uses: ./.workflows/.github/actions/setup
        with:
          working-directory: ${{ inputs.working-directory }}
          install: 'false'
      # The longest of the three: the consumer's code.sh fetches its registry
      # packs on every invocation, so this step can hang on the Semgrep registry
      # rather than on anything in the repository. A bound of its own, so the
      # log names the step instead of the job.
      - name: Scan source
        id: scan
        timeout-minutes: 20
        env:
          SECURITY_JOB: code
        run: bash "$WORKFLOWS_DIR/scripts/security/run-job.sh" "$SECURITY_JOB"
      - name: Upload SARIF
        if: ${{ !cancelled() && steps.scan.conclusion != 'failure' }}
        uses: actions/upload-artifact@v7
        with:
          name: security-sarif-code
          path: ${{ inputs.working-directory }}/.security/code.sarif
          if-no-files-found: error
          retention-days: 7
  policy:
    name: Policy
    needs: config
    if: ${{ inputs.policy && needs.config.outputs.enabled == 'true' && needs.config.outputs.policy == 'true' }}
    runs-on: ${{ inputs.linux-runner }}
    timeout-minutes: 15
    steps:
      - name: Checkout consumer
        uses: actions/checkout@v7
        with:
          repository: ${{ inputs.repository || github.repository }}
          ref: ${{ inputs.ref }}
          token: ${{ secrets.consumer-token || github.token }}
      - name: Checkout shared-workflows
        uses: actions/checkout@v7
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .workflows
          persist-credentials: false
      - name: Setup
        uses: ./.workflows/.github/actions/setup
        with:
          working-directory: ${{ inputs.working-directory }}
          install: 'false'
      - name: Scan the install policy
        id: scan
        env:
          SECURITY_JOB: policy
        run: bash "$WORKFLOWS_DIR/scripts/security/run-job.sh" "$SECURITY_JOB"
      - name: Upload SARIF
        if: ${{ !cancelled() && steps.scan.conclusion != 'failure' }}
        uses: actions/upload-artifact@v7
        with:
          name: security-sarif-policy
          path: ${{ inputs.working-directory }}/.security/policy.sarif
          if-no-files-found: error
          retention-days: 7
  verdict:
    name: Verdict
    needs: [config, deps, code, policy]
    # !cancelled(), not success(): a scanner that was switched off is skipped and
    # a scanner that crashed is failed, and both still have to reach the verdict -
    # "one scanner died" and "nothing was found" must never read the same. A
    # crashed scanner keeps the run red on its own job; this one adds the summary.
    if: ${{ !cancelled() && needs.config.result == 'success' && needs.config.outputs.enabled == 'true' }}
    runs-on: ${{ inputs.linux-runner }}
    timeout-minutes: 15
    # The only escalation in this workflow, and the reason a caller has to grant
    # anything at all. Naming `permissions:` resets the unnamed scopes to none,
    # so contents: read is re-declared or the checkouts below lose it.
    permissions:
      contents: read
      actions: read # workflow metadata for the SARIF upload
      security-events: write # upload the merged SARIF to code scanning
    steps:
      - name: Checkout consumer
        uses: actions/checkout@v7
        with:
          repository: ${{ inputs.repository || github.repository }}
          ref: ${{ inputs.ref }}
          token: ${{ secrets.consumer-token || github.token }}
      - name: Checkout shared-workflows
        uses: actions/checkout@v7
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .workflows
          persist-credentials: false
      - name: Setup
        uses: ./.workflows/.github/actions/setup
        with:
          working-directory: ${{ inputs.working-directory }}
          install: 'false'
      # merge-multiple is safe here only because each artifact carries a file
      # named after its own job - deps.sarif, code.sarif, policy.sarif. Two
      # artifacts carrying one filename would make the merge a coin toss, which
      # is what the release's per-platform build-info.json exists to avoid.
      #
      # Guarded on at least one scanner having succeeded: download-artifact fails
      # when its pattern matches nothing, and "every scanner was switched off" is
      # a case verdict.sh reports properly on its own.
      - name: Download scanner SARIF
        if: ${{ needs.deps.result == 'success' || needs.code.result == 'success' || needs.policy.result == 'success' }}
        uses: actions/download-artifact@v8
        with:
          pattern: security-sarif-*
          merge-multiple: true
          path: ${{ inputs.working-directory }}/.security
      - name: Verdict
        id: verdict
        run: bash "$WORKFLOWS_DIR/scripts/security/verdict.sh"
      # !cancelled(), so a verdict that failed on findings still gets those
      # findings into the Security tab - that run is exactly the one where they
      # matter. hashFiles guards the case where nothing was produced at all;
      # upload-sarif dies on an empty directory.
      #
      # The event branch is load-bearing: on a push both operands of the
      # full_name comparison are empty, so a bare equality would treat every push
      # as a fork and never upload anything.
      - name: Upload to code scanning
        if: >-
          ${{ !cancelled() && inputs.sarif-upload
          && (github.event_name != 'pull_request'
              || github.event.pull_request.head.repo.full_name == github.repository)
          && hashFiles(format('{0}/.security/*.sarif', inputs.working-directory)) != '' }}
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: ${{ inputs.working-directory }}/.security
          category: security
      # A fork's GITHUB_TOKEN is read-only whatever the block above requests, so
      # the upload cannot happen. The verdict still ran and still applied the
      # threshold; only the destination is missing, and an empty Security tab
      # must never be allowed to read as "scanned, nothing found".
      - name: Report the fork upload gap
        if: >-
          ${{ !cancelled() && inputs.sarif-upload
          && github.event_name == 'pull_request'
          && github.event.pull_request.head.repo.full_name != github.repository }}
        env:
          REASON: this run is a pull request from a fork, whose token is read-only whatever this workflow requests
        run: bash "$WORKFLOWS_DIR/scripts/security/sarif-upload-skipped.sh" "$REASON"
      - name: Report the disabled upload
        if: ${{ !cancelled() && !inputs.sarif-upload }}
        env:
          REASON: the caller passed sarif-upload false
        run: bash "$WORKFLOWS_DIR/scripts/security/sarif-upload-skipped.sh" "$REASON"
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
mise exec -- bats test/workflow-shape.bats
```

Expected: the whole file green, including the six cases from Step 1.

If `yq -r '.jobs.verdict.steps[] | select((.uses // "") | test("upload-sarif")) | .if'`
prints nothing, the folded `>-` block has collapsed the expression onto one line
with different whitespace than the assertion expects — the assertions compare
substrings, not whole strings, so check the substring actually present rather
than reformatting the YAML.

- [ ] **Step 5: Lint the workflow itself**

```bash
mise exec -- actionlint -color
mise exec -- zizmor --offline --min-severity medium .github
```

Expected: both silent. `zizmor`'s `template-injection` is the rule to watch:
every `${{ }}` in this file is in a `with:`, an `if:` or an `outputs:` map, and
no `run:` line interpolates anything — the two values a step needs
(`SECURITY_JOB`, `REASON`) travel through `env:` and are read as `"$VAR"`.

- [ ] **Step 6: Update the marked counts in README.md**

```bash
git add .github/workflows/check-security.yml
mise exec -- bash -c 'grep -l workflow_call .github/workflows/*.yml | grep -vc "/self-"'
mise exec -- bash -c 'git ls-files ".github/workflows/*.yml" | wc -l'
mise exec -- bats --count test/
```

Write the three printed numbers into `README.md` line 12
(`<!--count:reusable-workflows-->`, `<!--count:tests-->`), line 185
(`<!--count:workflows-->`) and line 196 (`<!--count:tests-->`).

- [ ] **Step 7: Run the full gate**

```bash
mise exec -- make check
```

Expected: green. `test/docs-facts.bats` is the case that fails if a count above
was mistyped; `test/consumer-contract.bats` stays green at this point because
`check-security` is not yet in its list — Task 3 adds it together with the guide
section it requires.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/check-security.yml test/workflow-shape.bats README.md
git commit -m "feat(ci): add check-security.yml, the consumer's scanners in CI

One job per scanner so a red run names the scanner, and one verdict that merges
their SARIF, writes the summary and applies the threshold. The verdict is the
only job with security-events: write.

The job graph is the AND of the caller's booleans and the consumer's
security-policy.json, resolved by a config job because an if: cannot read a
file. A fork cannot upload to code scanning, so the run says so rather than
going quiet, and the threshold still applies.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 3: The consumer guide section, the fixture caller and the README row

`test/consumer-contract.bats` fails without the guide section: every
`workflow_call` input of every workflow in its list needs a row, and the list has
to grow to include this one. The fixture caller is what the guide's example is
compared against byte for byte, and it is also what proves a caller has to grant
`security-events: write` — a caller capped at `contents: read` does not get a
permission error in a step, it gets a `startup_failure` with no jobs at all.

**Files:**
- Modify: `docs/consumer-guide.md` (a `### \`check-security.yml\`` section)
- Create: `test/fixtures/consumer-min/.github/workflows/ci-security.yml`
- Modify: `test/consumer-contract.bats` (two workflow lists, one caller-example index)
- Modify: `README.md` (the workflow catalogue row, and the `tests` count)

- [ ] **Step 1: Write the failing tests**

In `test/consumer-contract.bats`, add `check-security` to **both** workflow lists
— the one in *"every workflow_call input is documented in the guide's table for
that workflow"* and the one in *"every input the guide documents still exists in
that workflow"*. In each, replace:

```bash
  for wf in check-code check-unit check-e2e build-web publish-badges pr-title check-codeql \
    build-prepare build-ios build-android \
    publish-store publish-github-release publish-ota pr-release-notes; do
```

with:

```bash
  for wf in check-code check-unit check-e2e build-web publish-badges pr-title check-codeql \
    check-security build-prepare build-ios build-android \
    publish-store publish-github-release publish-ota pr-release-notes; do
```

Then extend the caller-example case. Replace:

```bash
  for spec in ci:1 ci-web:2 ci-pr-closed:3 ci-pr-title:4 ci-codeql:6; do
```

with:

```bash
  for spec in ci:1 ci-web:2 ci-pr-closed:3 ci-pr-title:4 ci-codeql:6 ci-security:8; do
```

`8` is the position the new ```yaml block takes when the section is added
immediately after `### \`check-codeql.yml\`` and before `## Release workflows`:
the blocks before it are at lines 253, 365, 418, 433, 470, 807 and 850. Confirm
it rather than trusting the number:

```bash
mise exec -- rg -n '^```yaml$' docs/consumer-guide.md
```

The new block must be the 8th line printed, and the existing 1–6 must be
unchanged.

- [ ] **Step 2: Run the tests and watch them fail**

```bash
mise exec -- bats test/consumer-contract.bats
```

Expected: three failures — no `### \`check-security.yml\`` section, no fixture
caller at `ci-security.yml`, and the block index resolving to nothing.

- [ ] **Step 3: Write the fixture caller**

Create `test/fixtures/consumer-min/.github/workflows/ci-security.yml`:

```yaml
name: Security
on:
  push:
    branches: [main]
    # No paths-ignore: check-code.yml's `changes` job is this family's single
    # docs classifier, and a second, narrower copy of it here would drift from it.
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
concurrency:
  group: ci-security-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  security:
    name: Security
    # The repository variable is the master switch, the same shape as
    # OTA_ENABLED and STORE_UPLOADS_ENABLED - except this one is opt-out, because
    # a generated app gets the deterministic scanners on. A skipped job is green,
    # so a repository that sets it to false never holds up a required check.
    if: ${{ vars.SECURITY_ENABLED != 'false' }}
    # A called workflow can only ever narrow the caller's token, never widen it.
    # check-security.yml's verdict job asks for security-events: write, so a
    # caller that grants less does not get a failed step - the whole run dies as
    # a startup_failure with no jobs at all, which is close to undebuggable from
    # the UI. That is not hypothetical: every CodeQL run on the first consumer
    # failed this way from the day the repository was pushed.
    permissions:
      contents: read
      actions: read
      security-events: write
    uses: blinkbitcoin/shared-workflows/.github/workflows/check-security.yml@v0
```

- [ ] **Step 4: Write the guide section**

In `docs/consumer-guide.md`, immediately after the `### \`check-codeql.yml\``
section and before `## Release workflows`, add:

````markdown
### `check-security.yml`

Jobs: `Config`, `Dependencies`, `Code`, `Policy`, `Verdict`.

The consumer's own security scanners, run in CI. Every scanner, the settings
resolver and the merge live in **your** repository under `scripts/security/`,
and `make check-security` runs the same files — so a green laptop and a green
pipeline are the same claim. This workflow owns the job graph, the permissions,
the artifact passing, the upload to code scanning and the run summary, and
nothing else. It ships no fallback scanner: a job that is switched on but whose
`scripts/security/<job>.sh` is missing fails, by name, rather than skipping
quietly.

**What decides whether a scanner runs.** Two things, together. The input below is
what this *tier* allows, and `security-policy.json` in your repository is what
your repository wants; a caller may narrow and may never widen. A job-level
`if:` cannot read a file, so the `Config` job runs your `scripts/security/config.mjs`
once and publishes the answer as job outputs the other jobs read. Values —
`severity`, `failOn` — are never inputs here: they live in
`security-policy.json`, with environment twins that win over it.

`"enabled": false` in `security-policy.json` (or `SECURITY_ENABLED=false`)
switches everything off, and every job then skips. A skipped job is green, so
`require-green-workflow` never waits on it. If the gate is on but every scanner
is off, the `Verdict` job fails rather than reporting a clean run: a pipeline
that scans nothing while reporting green is worse than one that is red.

| Input | Meaning |
| --- | --- |
| `repository`, `ref`, `working-directory`, `linux-runner`, `macos-runner`, `native-cache-version` | The family's common six. `macos-runner` and `native-cache-version` are unused here and carried for consistency |
| `deps` | Allow the dependency scanner (your `check-security-deps`, osv-scanner over the lockfile). Default `true` |
| `code` | Allow the source scanner (your `check-security-code`, Semgrep over app source). Default `true` |
| `policy` | Allow the install-policy scanner (your `check-security-policy`). Default `true` |
| `sarif-upload` | Upload the merged SARIF to code scanning. Default `true`. Off makes the run say so in the summary rather than go quiet, and the verdict still applies the threshold |

Secrets: `consumer-token` only, and only for a private consumer repository.
There are no outputs: the caller already has `docs-only` from `check-code.yml`,
and a second docs classifier would be a second rule that drifts.

**Permissions your caller must grant.** The `Verdict` job is the only one that
escalates, and it asks for `security-events: write` plus `actions: read`. A
called workflow can only narrow the caller's token, so a caller that grants less
does not get a failed step — the whole run dies as a `startup_failure` with no
jobs at all.

**Forks.** A pull request from a fork gets a read-only `GITHUB_TOKEN` whatever
this workflow requests, so the SARIF cannot reach code scanning. The gate is not
weaker there: the verdict still merges, still applies the threshold and still
fails the run on a blocking finding. Only the destination is missing, and the run
says so — a `::warning::` and a line in the summary — so an empty Security tab
can never read as "scanned, nothing found".

```yaml
# .github/workflows/ci-security.yml
name: Security
on:
  push:
    branches: [main]
    # No paths-ignore: check-code.yml's `changes` job is this family's single
    # docs classifier, and a second, narrower copy of it here would drift from it.
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
concurrency:
  group: ci-security-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  security:
    name: Security
    # The repository variable is the master switch, the same shape as
    # OTA_ENABLED and STORE_UPLOADS_ENABLED - except this one is opt-out, because
    # a generated app gets the deterministic scanners on. A skipped job is green,
    # so a repository that sets it to false never holds up a required check.
    if: ${{ vars.SECURITY_ENABLED != 'false' }}
    # A called workflow can only ever narrow the caller's token, never widen it.
    # check-security.yml's verdict job asks for security-events: write, so a
    # caller that grants less does not get a failed step - the whole run dies as
    # a startup_failure with no jobs at all, which is close to undebuggable from
    # the UI. That is not hypothetical: every CodeQL run on the first consumer
    # failed this way from the day the repository was pushed.
    permissions:
      contents: read
      actions: read
      security-events: write
    uses: blinkbitcoin/shared-workflows/.github/workflows/check-security.yml@v0
```
````

The fenced example must be **byte for byte** the fixture file created in Step 3,
apart from the leading `# .github/workflows/ci-security.yml` comment line, which
`guide_yaml_block()` strips. If the comparison fails, copy the fixture rather
than retyping it:

```bash
{ echo '# .github/workflows/ci-security.yml'; cat test/fixtures/consumer-min/.github/workflows/ci-security.yml; }
```

- [ ] **Step 5: Add the README catalogue row**

First confirm no other doc carries a parallel list:

```bash
mise exec -- rg -n 'check-codeql' README.md AGENTS.md CONTRIBUTING.md docs/*.md
```

Only `README.md` should match. Add a row to the *"The rest, on a pull request or
a push"* table, immediately after the `check-codeql.yml` row:

```markdown
| `check-security.yml`  | `Config`<br>`Dependencies`<br>`Code`<br>`Policy`<br>`Verdict` | The consumer's security scanners, one job each, then one verdict that merges the SARIF and applies the threshold |
```

- [ ] **Step 6: Run the tests and watch them pass**

```bash
mise exec -- bats test/consumer-contract.bats
mise exec -- bats test/workflow-shape.bats
```

Expected: both green. `workflow-shape.bats` matters here too: the new fixture
caller is read by *"every fixture caller grants the write permissions its callee
needs"* in `consumer-contract.bats`, which is the case that would catch the
`startup_failure` shape if the `security-events: write` grant were dropped from
the example.

- [ ] **Step 7: Update the `tests` count and run the full gate**

```bash
git add test/fixtures/consumer-min/.github/workflows/ci-security.yml
mise exec -- bats --count test/
```

Write the number into both `<!--count:tests-->` markers in `README.md`, then:

```bash
mise exec -- make check
```

Expected: green. `spell` (typos) reads `docs/` and `README.md`, so a misspelling
in the new section fails here; `test/fixtures/**` is excluded from it.

- [ ] **Step 8: Commit**

```bash
git add docs/consumer-guide.md test/fixtures/consumer-min/.github/workflows/ci-security.yml \
  test/consumer-contract.bats README.md
git commit -m "docs(ci): document check-security.yml and its caller

Every input gets a row, the caller example is the fixture byte for byte, and
the README catalogue gains the workflow. The fixture caller is what holds the
security-events: write grant to the contract - a caller that grants less dies as
a startup_failure with no jobs at all.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 4: The pull request

**Files:** none. This task opens the pull request and says, in its body, what
the two stages after it still owe.

- [ ] **Step 1: Run the full gate one more time, from a clean tree**

```bash
git status --porcelain
mise exec -- make check
```

Expected: no output from the first, green from the second. `make check` is the
gate this repository's `self-ci.yml` runs job by job; nothing narrower counts as
verification.

- [ ] **Step 2: Push and open the pull request**

```bash
git push -u origin feat/check-security-workflow
```

Title: `feat(ci): add check-security.yml`

Body, verbatim in substance:

- What the workflow is, and that every scanner, the resolver and the merge live
  in the consumer.
- **Stage 3 is blocked on this releasing.** The template's call sites cannot
  merge until `v0` carries `check-security.yml`: a `uses:` of a missing workflow
  file is a `startup_failure` for the whole run, on `main` too, which would red
  the template's internal build gate.
- **Three scanner jobs, not nine.** `deps`, `code` and `policy` are the runners
  that exist. `sbom`, `bundle`, `mobile`, `binaries`, `review` and `openant` are
  in `security-policy.json`'s defaults and in `verdict.mjs`'s `ENGINE_OF`, and
  have no runner anywhere. Each gains a job here in the same change that adds
  its runner to the template — never before.
- **After the release:** watch the template's next CD / Internal run. No gate in
  this repository can execute its own reusable workflows, so the only real proof
  is a `scratch/*` branch of the template calling
  `check-security.yml@<sha>` on a pull request.
- Do **not** quote a skip token anywhere in the body; describe it in words.

- [ ] **Step 3: Confirm the commits landed with the scopes they claim**

```bash
git log --oneline origin/main..HEAD
```

Expected: three commits, two `feat(ci)` and one `docs(ci)`. A scope outside
commitlint's enum is rejected silently under a pipe, and a new reusable workflow
shipped under a `docs` scope would produce no version pull request at all — `v0`
would never carry the file, and Stage 3 would stay blocked with nothing visibly
wrong.

---

## What the spec leaves open, and what this plan chose

Recorded here so the next reader does not have to re-derive it.

1. **The spec's SARIF category is `security/<job>`; this plan uploads once under
   `security`.** Per-job categories need one `upload-sarif` step per job, in the
   one job holding `security-events: write`. With a fixed three that is
   writable, but each step would have to be individually guarded on its own
   artifact existing, and the set changes in every later stage. One upload of the
   `.security/` directory keeps the per-tool attribution that actually shows up
   in the Security tab (`runs[].tool.driver.name`, which every scanner sets), at
   the cost of the category string. Revisit if per-scanner alert filtering turns
   out to matter.

2. **The spec's job table lists nine scanners; Stage 1 built three.**
   `security-policy.json` ships `sbom`, `bundle` and `binaries` as
   `"enabled": true` with no runner behind any of them. Under the spec's own
   "a missing script fails loudly" rule, declaring those jobs now would fail
   every consumer. This plan declares jobs only for runners that exist and says
   so out loud; the defaults in the consumer's policy file are Stage 1's problem
   to reconcile, and the honest fix there is to ship the runners, not to change
   the defaults.

3. **The spec places `bundle`, `sbom`, `binaries` and `mobile` at release time
   and `review` on the release-please pull request.** All of that is caller
   configuration, and all of it is Stage 3 or later. Nothing about it constrains
   this workflow beyond the booleans-only input rule, which is already honoured.

4. **Display names.** The spec asks for one name per scanner across the make
   target, the CI job and the policy key — which argues for a job displayed as
   `Deps`. The house rule is that a reader never meets a vague abbreviation, and
   `check-code.yml` already displays `Dependencies`. This plan spells it out:
   the *identity* (`deps`) is the input name, the policy key and the artifact
   name, all of which appear in the run; the display name is its spelled-out
   form.

5. **`SECURITY_ENABLED` names two different things.** It is a repository
   *variable* read by the caller's `if:`, and an environment *variable* read by
   `config.mjs`. A repository variable is not automatically in a job's
   environment, so the two do not reach each other. That is fine — they are two
   layers of the same switch, in the spec's own resolution order — but a reader
   who sets the repository variable and expects `config.mjs` to see it will be
   surprised. The guide section says which is which.
