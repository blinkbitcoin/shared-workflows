#!/usr/bin/env bats
# The published contract, held together inside this repository:
#   1. every script docs/consumer-guide.md's script-contract table marks "yes"
#      exists in the fixture consumer's package.json - the table is *parsed*, so
#      adding a row to the guide immediately becomes an assertion;
#   2. every input a reusable workflow declares is documented in that workflow's
#      own section of the guide;
#   3. the guide's caller examples are the fixture's files, byte for byte;
#   4. contract.json names every script CI runs, which is what each consumer's
#      Contract job reads to hold that consumer's `make ci` to CI.
# Everything here reads this repository and test/fixtures/consumer-min only. A
# real consumer is never checked out: it is held to the contract by its own
# Contract job (packages/dev-config/bin/check-consumer-contract.mjs), against the
# version of this repository it calls, and fails its own PR when it drifts.
load test_helper

GUIDE="$REPO_ROOT/docs/consumer-guide.md"
# Exported: the contract-table cases at the bottom read it from node's process.env.
export GUIDE
CONSUMER="$FIXTURES/consumer-min"

require_consumer() {
  [ -f "$CONSUMER/package.json" ] || fail "no package.json in the fixture consumer at $CONSUMER"
}

# Prints the consumer's package.json script names, one per line.
consumer_scripts() {
  node -e 'const p=require(process.argv[1]);console.log(Object.keys(p.scripts||{}).join("\n"))' \
    "$CONSUMER/package.json"
}

# Prints the script names from the "## Script contract" table whose
# "Present in the template?" cell starts with "yes", one per line.
guide_table_yes_scripts() {
  awk -F'|' '
    /^## Script contract/ { inside = 1; next }
    inside && /^#+ / { exit }
    inside && NF >= 5 {
      cell = $4
      gsub(/^[ \t]+/, "", cell); gsub(/[ \t]+$/, "", cell)
      if (cell !~ /^yes/) next
      if (match($2, /`[^`]+`/)) print substr($2, RSTART + 1, RLENGTH - 2)
    }
  ' "$GUIDE"
}

# Prints the section of the guide under the heading "### `NAME`", stopping at
# the next heading of any level.
guide_section() {
  awk -v want="### \`$1\`" '
    $0 == want { inside = 1; next }
    inside && /^#+ / { exit }
    inside { print }
  ' "$GUIDE"
}

# Prints the Nth ```yaml block of the guide (1-based), dropping a leading
# "# .github/workflows/..." filename comment if present.
guide_yaml_block() {
  awk -v want="$1" '
    /^```yaml$/ { n++; if (n == want) inside = 1; next }
    inside && /^```$/ { exit }
    inside { print }
  ' "$GUIDE" | awk 'NR == 1 && /^# \.github\/workflows\// { next } { print }'
}

@test "every script the guide's contract table marks yes exists in the consumer" {
  require_consumer
  wanted="$(guide_table_yes_scripts)"
  [ "$(grep -c . <<<"$wanted")" -ge 10 ] \
    || fail "parsed only '$wanted' from the guide's script-contract table"
  scripts="$(consumer_scripts)"
  missing=()
  while read -r name; do
    [ -n "$name" ] || continue
    grep -qxF "$name" <<<"$scripts" || missing+=("$name")
  done <<<"$wanted"
  [ "${#missing[@]}" -eq 0 ] \
    || fail "the guide marks these 'yes' but $CONSUMER has no such script: ${missing[*]}"
}

@test "knip is a consumer devDependency (the guide's binary-fallback claim)" {
  require_consumer
  run node -e 'const p=require(process.argv[1]);process.exit(p.devDependencies&&p.devDependencies.knip?0:1)' \
    "$CONSUMER/package.json"
  [ "$status" -eq 0 ]
}

@test "knip is deliberately NOT a consumer package.json script" {
  require_consumer
  run grep -qxF knip <<<"$(consumer_scripts)"
  [ "$status" -ne 0 ]
}

@test "the guide's caller examples match the fixture's workflow files byte for byte" {
  # `name:block` rather than a running counter: the guide has ```yaml blocks
  # that are not caller examples (the secrets-policy snippet is block 5), so the
  # index and the position in this list stopped being the same number once
  # check-codeql.yml's section landed further down the page.
  for spec in ci:1 ci-web:2 ci-pr-closed:3 ci-pr-title:4 ci-codeql:6 ci-security:8; do
    wf="${spec%:*}"
    n="${spec##*:}"
    file="$FIXTURES/consumer-min/.github/workflows/$wf.yml"
    [ -f "$file" ] || fail "missing fixture caller $file"
    diff -u "$file" <(guide_yaml_block "$n") \
      || fail "the guide's $wf.yml example has drifted from $file"
  done
}

# Everything from `on:` up to the next top-level key.
on_block() {
  awk '/^on:/ { inside = 1; print; next }
       inside && /^[^[:space:]#]/ { exit }
       inside { print }' "$1"
}

# The caller the guide tells consumers to copy must not carry a `paths-ignore`:
# that would be a second, narrower docs rule competing with check-code.yml's
# classifier, the exact defect PR 3 removed. The fixture is the guide's example
# byte for byte (above), so asserting it here asserts what consumers copy.
@test "the fixture's ci.yml triggers carry no paths-ignore" {
  file="$FIXTURES/consumer-min/.github/workflows/ci.yml"
  block="$(on_block "$file")"
  [ "$(grep -c . <<<"$block")" -ge 5 ] \
    || fail "read no trigger block from $file - the parser or the file shape changed"
  ! grep -qE '^[[:space:]]*paths-ignore:' <<<"$block" \
    || fail "$file's triggers carry a paths-ignore, a second docs rule beside check-code.yml's classifier"
}

# The guide's `docs-globs` row restates changed-class.sh's default pattern by
# hand, with markdown pipe escaping. Two hand-maintained copies of a regex is
# exactly the kind of drift this suite exists to catch.
# Same rule as ci.yml above, for the same reason: check-codeql.yml's `changes` job is
# the single docs classifier, so a `paths-ignore` on the caller's triggers would
# be a second, narrower copy of it. esign's caller still carries one; ours must
# not grow one back. The schedule trigger is asserted too - it is what makes a
# newly published query re-scan an idle main, and it is the one trigger a
# reviewer is most likely to think is redundant.
@test "the fixture's ci-codeql.yml has no paths-ignore and keeps its weekly schedule" {
  require_consumer
  file="$CONSUMER/.github/workflows/ci-codeql.yml"
  [ -f "$file" ] || fail "no ci-codeql.yml at $file"
  block="$(on_block "$file")"
  [ "$(grep -c . <<<"$block")" -ge 5 ] \
    || fail "read no trigger block from $file - the parser or the file shape changed"
  ! grep -qE '^[[:space:]]*paths-ignore:' <<<"$block" \
    || fail "$file's triggers carry a paths-ignore, a second docs rule beside check-codeql.yml's classifier"
  grep -q 'schedule' <<<"$block" \
    || fail "$file has no schedule trigger, so a new query never re-scans an idle main"
}

@test "the guide's docs-globs row quotes changed-class.sh's default pattern" {
  script=$(sed -n "s/^default_docs_globs='\(.*\)'$/\1/p" "$REPO_ROOT/scripts/ci/changed-class.sh")
  [ -n "$script" ] || fail "could not read default_docs_globs from scripts/ci/changed-class.sh"
  # The row's first backticked run starting with ^docs/, with \| unescaped.
  row=$(grep -F '| `docs-globs` |' "$GUIDE" | head -1)
  [ -n "$row" ] || fail "no docs-globs row in $GUIDE"
  quoted=$(grep -oE '`\^docs/[^`]*`' <<<"$row" | head -1 | tr -d '`' | sed 's/\\|/|/g')
  [ "$quoted" = "$script" ] \
    || fail "the guide's docs-globs row quotes '$quoted' but changed-class.sh defaults to '$script'"
}

@test "every workflow_call input is documented in the guide's table for that workflow" {
  command -v yq >/dev/null || skip "yq not installed"
  missing=()
  for wf in check-code check-unit check-e2e build-web publish-badges pr-title check-codeql \
    check-security build-prepare build-ios build-android \
    publish-store publish-github-release publish-ota pr-release-notes; do
    file="$REPO_ROOT/.github/workflows/$wf.yml"
    section="$(guide_section "$wf.yml")"
    [ -n "$section" ] || fail "no '### \`$wf.yml\`' section in docs/consumer-guide.md"
    inputs="$(yq -r '.on.workflow_call.inputs | keys | .[]' "$file")" \
      || fail "yq failed to read inputs from $file"
    # Every one of these declares at least the six common inputs; an empty read
    # means the file moved or its shape changed, not that it has no inputs.
    [ "$(grep -c . <<<"$inputs")" -ge 6 ] || fail "read only '$inputs' from $file"
    while read -r input; do
      [ -n "$input" ] || continue
      grep -qF -- "\`$input\`" <<<"$section" || missing+=("$wf.yml:$input")
    done <<<"$inputs"
  done
  [ "${#missing[@]}" -eq 0 ] || fail "undocumented inputs: ${missing[*]}"
}

@test "every input the guide documents still exists in that workflow" {
  # The other direction. The case above catches an input added to a workflow and
  # never written down; this one catches a row left behind when an input is
  # removed or renamed - a phantom a reader would try to pass.
  command -v yq >/dev/null || skip "yq not installed"
  phantom=()
  for wf in check-code check-unit check-e2e build-web publish-badges pr-title check-codeql \
    check-security build-prepare build-ios build-android \
    publish-store publish-github-release publish-ota pr-release-notes; do
    file="$REPO_ROOT/.github/workflows/$wf.yml"
    section="$(guide_section "$wf.yml")"
    inputs="$(yq -r '.on.workflow_call.inputs | keys | .[]' "$file")"
    # Only the first column of a table row: prose and "Meaning" cells name
    # plenty of things that are not inputs of this workflow.
    while read -r row; do
      name="$(sed -E 's/^\| `([a-z0-9-]+)`.*/\1/' <<<"$row")"
      [ "$name" != "$row" ] || continue
      # Rows that list several inputs at once ("`repository`, `ref`, ...") are
      # the common quintet, documented as a group on purpose.
      case "$row" in *'`, `'*) continue ;; esac
      grep -qxF "$name" <<<"$inputs" || phantom+=("$wf.yml:$name")
    done <<<"$(grep -E '^\| `[a-z0-9-]+` \|' <<<"$section")"
  done
  [ "${#phantom[@]}" -eq 0 ] || fail "the guide documents inputs that no longer exist: ${phantom[*]}"
}

@test "pr-closed.yml really declares no workflow_call inputs" {
  command -v yq >/dev/null || skip "yq not installed"
  run yq -r '.on.workflow_call.inputs // "null"' "$REPO_ROOT/.github/workflows/pr-closed.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

# --- contract.json knows every script CI runs --------------------------------
#
# A consumer's Contract job holds its `make ci` to the gates CI runs
# (gate.make-ci-reaches-ci, gate.ci-runs-make-ci in contract.json). It learns
# which scripts those are from contract.json, never from a YAML parser - it runs
# before setup, on plain node. So contract.json has to name every script a
# checks/unit step runs, with the input that switches it. These cases hold it to
# that, from this repository alone: no consumer checkout is involved.

# `script<TAB>condition` for every check-code.yml/check-unit.yml step that runs a consumer
# script: SCRIPT_NAME for run-script.sh, the positional name for
# run-consumer-or.sh. An expression SCRIPT_NAME (check-unit.yml) is resolved to the
# defaults of the `*-script` inputs it names.
ci_steps() {
  local f
  for f in check-code check-unit; do
    yq -o=json '.' "$REPO_ROOT/.github/workflows/$f.yml"
  done | node -e '
let buf = "";
process.stdin.on("data", (d) => (buf += d)).on("end", () => {
  // yq -o=json prints one document per file, back to back.
  const docs = buf.replace(/}\s*{/g, "}\u0000{").split("\u0000").map((t) => JSON.parse(t));
  for (const wf of docs) {
    const inputs = wf.on.workflow_call.inputs;
    for (const job of Object.values(wf.jobs)) {
      for (const step of job.steps ?? []) {
        const run = step.run ?? "";
        const cond = `${step.if ?? ""} ${step.env?.SCRIPT_NAME ?? ""}`;
        const positional = /run-consumer-or\.sh" \x27([^\x27]+)\x27/.exec(run);
        if (positional) { console.log(`${positional[1]}\t${cond}`); continue; }
        if (!/run-script\.sh/.test(run)) continue;
        const name = String(step.env?.SCRIPT_NAME ?? "");
        if (!name.includes("${{")) { console.log(`${name}\t${cond}`); continue; }
        for (const m of name.matchAll(/inputs\.([a-z-]+-script)/g)) console.log(`${inputs[m[1]].default}\t${cond}`);
      }
    }
  }
});'
}

@test "every script a checks or unit step runs has a contract requirement gated on that step's input" {
  command -v yq >/dev/null || skip "yq not installed"
  steps="$(ci_steps)"
  [ "$(grep -c . <<<"$steps")" -ge 15 ] || fail "parsed only '$steps' - has the step shape changed?"
  problems="$(STEPS="$steps" node -e '
const c = require(process.argv[1]);
const out = [];
for (const line of process.env.STEPS.split("\n")) {
  const [script, cond] = line.split("\t");
  // check-unit.yml falls back to plain `test` when coverage is off; the contract
  // names test:coverage for that step, gated on the same input.
  if (script === "test") continue;
  const req = c.requirements.find((r) => ["package-script", "script-or-dep"].includes(r.kind) && r.target === script);
  if (!req) { out.push(`${script}: no requirement in contract.json`); continue; }
  if (req.toggle && !cond.includes(`inputs.${req.toggle.split(":")[1]}`)) out.push(`${script}: contract toggle ${req.toggle} is not what switches the step (${cond.trim()})`);
}
console.log(out.join("\n"));
' "$REPO_ROOT/packages/dev-config/contract.json")"
  [ -z "$problems" ] || fail "contract.json disagrees with the workflows:
$problems"
}

@test "every checks or unit script requirement in the contract is run by some step" {
  command -v yq >/dev/null || skip "yq not installed"
  names="$(ci_steps | cut -f1 | sort -u)"
  stale="$(NAMES="$names" node -e '
const c = require(process.argv[1]);
const names = new Set(process.env.NAMES.split("\n"));
console.log(c.requirements
  .filter((r) => ["package-script", "script-or-dep"].includes(r.kind) && ["checks", "unit"].includes(r.profile))
  .filter((r) => !names.has(r.target)).map((r) => r.id).join(" "));
' "$REPO_ROOT/packages/dev-config/contract.json")"
  [ -z "$stale" ] || fail "contract.json requires scripts no checks/unit step runs: $stale"
}

@test "the contract's App Review names are exactly the secrets publish-store.yml passes" {
  command -v yq >/dev/null || skip "yq not installed"
  declared="$(yq -r '.on.workflow_call.secrets | keys | .[] | select(test("^APP_REVIEW_"))' \
    "$REPO_ROOT/.github/workflows/publish-store.yml" | sort)"
  contract="$(node -e '
const c = require(process.argv[1]);
console.log(c.requirements.find((r) => r.id === "lane.app-review-env").target.slice().sort().join("\n"));
' "$REPO_ROOT/packages/dev-config/contract.json")"
  [ "$(grep -c . <<<"$declared")" -ge 7 ] || fail "found only '$declared' in publish-store.yml"
  [ "$declared" = "$contract" ] || fail "publish-store.yml passes:
$declared
contract.json lists:
$contract"
}

# --- a caller must grant what the workflow it calls asks for -----------------
#
# GitHub only ever lets a called workflow NARROW the caller's token, never widen
# it. So a caller capped at `contents: read` calling a workflow whose job wants
# `security-events: write` does not get a permission error in a step - the whole
# run dies as a `startup_failure` with no jobs at all, which is close to
# undebuggable from the UI.
#
# That is not hypothetical: every CodeQL run on the consumer failed this way
# from the day the repo was pushed, and the caller carried a comment asserting
# the opposite - that the called workflow declaring its own escalation meant
# nothing had to be granted here.
#
# Checked against the fixture, which is what consumers copy.

# The union of permissions every job of a reusable workflow asks for.
callee_permissions() {
  yq -r '[.jobs[].permissions // {} | to_entries[] | select(.value == "write") | .key] | unique | .[]' \
    "$REPO_ROOT/.github/workflows/$1.yml"
}

@test "every fixture caller grants the write permissions its callee needs" {
  command -v yq >/dev/null || skip "yq not installed"
  for f in "$FIXTURES"/consumer-min/.github/workflows/*.yml; do
    while IFS=$'\t' read -r job called; do
      [ -n "$called" ] || continue
      # Only this family's reusable workflows; an action reference is not one.
      case "$called" in *shared-workflows/.github/workflows/*) ;; *) continue ;; esac
      wf=$(basename "${called%@*}" .yml)
      [ -f "$REPO_ROOT/.github/workflows/$wf.yml" ] || continue
      # Job-level permissions override the workflow's; absent, the workflow's
      # apply to every job. pr-closed.yml grants at the top level, and reading
      # only the job level reported it as under-granted when it is not.
      granted=$(yq -r "((.jobs.\"$job\".permissions // .permissions) // {}) | to_entries[] | select(.value == \"write\") | .key" "$f")
      while read -r need; do
        [ -n "$need" ] || continue
        grep -qxF "$need" <<<"$granted" \
          || fail "$(basename "$f") job '$job' calls $wf.yml, whose jobs need '$need: write', but grants: ${granted:-（none）}
A called workflow cannot widen the caller's token - this run would die as a startup_failure with no jobs."
      done < <(callee_permissions "$wf")
    done < <(yq -r '.jobs | to_entries[] | select(.value.uses != null) | .key + "\t" + .value.uses' "$f")
  done
}

# --- the contract table --------------------------------------------------
#
# packages/dev-config/contract.json is what the checker reads and what the
# adoption docs are written from. The guide's own tables are the prose version
# of the same facts. Two statements of one contract drift; these hold them
# together in both directions.

@test "every consumer script the contract table names appears in the guide's script table" {
  run node -e '
    const fs = require("fs");
    const contract = require(`${process.env.REPO_ROOT}/packages/dev-config/contract.json`);
    const guide = fs.readFileSync(process.env.GUIDE, "utf8");
    const table = guide.split("## Script contract")[1] ?? "";
    const missing = contract.requirements
      .filter((r) => r.kind === "package-script" || r.kind === "script-or-dep")
      .map((r) => r.target)
      .filter((name) => !table.includes(`\`${name}\``));
    if (missing.length > 0) {
      throw new Error(`in contract.json but not in the script table of the guide: ${missing.join(", ")}`);
    }
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "every workflow input the contract table gates on exists in that workflow" {
  # A toggle renamed in a workflow and not here would silently make a
  # requirement unconditional - the exact failure this file exists to prevent.
  run node -e '
    const fs = require("fs");
    const root = process.env.REPO_ROOT;
    const contract = require(`${root}/packages/dev-config/contract.json`);
    const wrong = [];
    for (const req of contract.requirements) {
      if (!req.toggle) continue;
      const [workflow, input] = req.toggle.split(":");
      const text = fs.readFileSync(`${root}/.github/workflows/${workflow}`, "utf8");
      const block = text.split(/^    secrets:$|^    outputs:$/m)[0];
      if (!new RegExp(`^      ${input}:$`, "m").test(block)) {
        wrong.push(`${req.id} gates on ${req.toggle}, which ${workflow} does not declare`);
      }
    }
    if (wrong.length > 0) throw new Error(wrong.join("; "));
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the contract table agrees with each workflow about that input's default" {
  # `defaultOn` decides whether an absent script is a finding at all. A default
  # flipped in the workflow and not here makes the report wrong in the one
  # direction that matters: silence about a gate that is in fact running.
  run node -e '
    const fs = require("fs");
    const root = process.env.REPO_ROOT;
    const contract = require(`${root}/packages/dev-config/contract.json`);
    const wrong = [];
    for (const req of contract.requirements) {
      if (!req.toggle) continue;
      const [workflow, input] = req.toggle.split(":");
      const text = fs.readFileSync(`${root}/.github/workflows/${workflow}`, "utf8");
      const after = text.split(new RegExp(`^      ${input}:$`, "m"))[1] ?? "";
      const declared = /^        default: (true|false)$/m.exec(after.split(/^      [a-z]/m)[0]);
      if (!declared) continue;
      const on = declared[1] === "true";
      if (on !== req.defaultOn) {
        wrong.push(`${req.id}: contract says defaultOn=${req.defaultOn}, ${workflow} defaults ${input} to ${declared[1]}`);
      }
    }
    if (wrong.length > 0) throw new Error(wrong.join("; "));
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "every guide anchor the contract table points at exists in the guide" {
  run node -e '
    const fs = require("fs");
    const contract = require(`${process.env.REPO_ROOT}/packages/dev-config/contract.json`);
    const guide = fs.readFileSync(process.env.GUIDE, "utf8");
    // GitHub derives an anchor by lowercasing a heading, dropping anything but
    // word characters, spaces and hyphens, then replacing EACH remaining space
    // with a hyphen - not each run of them. "The Playwright / export contract"
    // becomes the-playwright--export-contract, with two hyphens where the
    // slash was, and a /\s+/ collapse here would report the guide as linking
    // to an anchor it does not have when in fact it links correctly.
    const anchors = new Set(
      [...guide.matchAll(/^#+ (.+)$/gm)].map(([, h]) =>
        h.toLowerCase().replace(/[^\w\s-]/g, "").trim().replace(/\s/g, "-"),
      ),
    );
    const missing = [...new Set(contract.requirements.map((r) => r.guide))].filter((a) => !anchors.has(a));
    if (missing.length > 0) throw new Error(`contract.json points at anchors the guide does not have: ${missing.join(", ")}`);
  '
  [ "$status" -eq 0 ] || fail "$output"
}
