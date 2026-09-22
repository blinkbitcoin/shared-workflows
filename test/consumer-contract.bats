#!/usr/bin/env bats
# The published contract, checked three ways:
#   1. every script docs/consumer-guide.md's script-contract table marks "yes"
#      exists in a consumer's package.json — the table is *parsed*, so adding a
#      row to the guide immediately becomes an assertion;
#   2. every input a reusable workflow declares is documented in that workflow's
#      own section of the guide;
#   3. the guide's four caller examples are the files a consumer actually ships;
#   4. the real consumer's `ci.yml` keeps the fixture's trigger block, so a
#      `paths-ignore` cannot come back as a second docs rule beside the
#      classifier. (3) compares the guide to the fixture only — it would not
#      catch that on its own.
# Runs against test/fixtures/consumer-min by default, so all of this is asserted
# on every push including self-ci. Set WORKFLOWS_CONSUMER_ROOT to a real consumer
# checkout (e.g. a react-native-mobile-template clone) to assert against that
# instead; the consumer tests skip with a message if that path has no
# package.json.
load test_helper

GUIDE="$REPO_ROOT/docs/consumer-guide.md"
# Exported: the contract-table cases at the bottom read it from node's process.env.
export GUIDE
CONSUMER="${WORKFLOWS_CONSUMER_ROOT:-$FIXTURES/consumer-min}"

require_consumer() {
  [ -f "$CONSUMER/package.json" ] || skip "no consumer package.json at $CONSUMER (WORKFLOWS_CONSUMER_ROOT)"
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
  # codeql.yml's section landed further down the page.
  for spec in ci:1 web:2 pr-closed:3 pr-title:4 codeql:6; do
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

# The byte-identity case above compares the guide to the FIXTURE, and says
# nothing about the real consumer - whose ci.yml legitimately diverges further
# down (`release-checks: true`), so a whole-file diff is not available. The
# `on:` block is the part that must not diverge: a `paths-ignore` there is a
# second, narrower docs rule competing with checks.yml's classifier, which is
# the exact defect PR 3 removed and the one thing nothing else here would
# notice coming back.
@test "the consumer's ci.yml trigger block matches the fixture's (no paths-ignore)" {
  require_consumer
  file="$CONSUMER/.github/workflows/ci.yml"
  [ -f "$file" ] || fail "no ci.yml at $file"
  fixture="$FIXTURES/consumer-min/.github/workflows/ci.yml"
  [ "$(grep -c . <<<"$(on_block "$fixture")")" -ge 5 ] \
    || fail "read no trigger block from $fixture - the parser or the file shape changed"
  diff -u <(on_block "$fixture") <(on_block "$file") \
    || fail "$file's trigger block has drifted from the fixture's; a paths-ignore here would be a second docs rule competing with checks.yml's classifier"
}

# The guide's `docs-globs` row restates changed-class.sh's default pattern by
# hand, with markdown pipe escaping. Two hand-maintained copies of a regex is
# exactly the kind of drift this suite exists to catch.
# Same rule as ci.yml above, for the same reason: codeql.yml's `changes` job is
# the single docs classifier, so a `paths-ignore` on the caller's triggers would
# be a second, narrower copy of it. esign's caller still carries one; ours must
# not grow one back. The schedule trigger is asserted too - it is what makes a
# newly published query re-scan an idle main, and it is the one trigger a
# reviewer is most likely to think is redundant.
@test "the consumer's codeql.yml has no paths-ignore and keeps its weekly schedule" {
  require_consumer
  file="$CONSUMER/.github/workflows/codeql.yml"
  [ -f "$file" ] || fail "no codeql.yml at $file"
  block="$(on_block "$file")"
  [ "$(grep -c . <<<"$block")" -ge 5 ] \
    || fail "read no trigger block from $file - the parser or the file shape changed"
  ! grep -q 'paths-ignore' <<<"$block" \
    || fail "$file's triggers carry a paths-ignore, a second docs rule beside codeql.yml's classifier"
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
  for wf in checks unit e2e web badges pr-title codeql \
    expo-prepare expo-build-ios expo-build-android \
    fastlane-lane github-release expo-ota-publish release-pr-notes; do
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
  for wf in checks unit e2e web badges pr-title codeql \
    expo-prepare expo-build-ios expo-build-android \
    fastlane-lane github-release expo-ota-publish release-pr-notes; do
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

# --- the CI gate set and the consumer's `make` gate set are the same set ------
#
# The template's Makefile used to head its gate section "each is what CI runs",
# and AGENTS.md repeated it. It was not true: i18n drift, codegen drift,
# lockfile provenance and the licence check all ran through `make check` and
# through no CI job at all, so a green local gate implied coverage CI was not
# providing. Nothing detected the gap, because the claim lived in a comment.
#
# These cases move the claim into a mechanism. They read the CI side out of the
# workflow YAML and the local side out of the consumer's Makefile, so neither
# is a hand-maintained list that can go stale on its own.

# Every SCRIPT_NAME the reusable workflows hand to run-script.sh or
# run-consumer-or.sh, one per line.
# Steps gated on an input that defaults to false are excluded: those gates are
# opt-in in CI by design (a prebuild of both platforms and a web export are
# minutes each), so `make ci` not running them is the intended arrangement, not
# drift. `make check-slow` is where they live locally.
ci_script_names() {
  local optional f line name cond
  # Inputs that default to false. Their steps are opt-in in CI by design - a
  # prebuild of both platforms and a web export are minutes each - so `make ci`
  # not running them is the intended arrangement, not drift. `make check-slow`
  # is where they live locally.
  optional="$(yq -r '.on.workflow_call.inputs | to_entries[] | select(.value.default == false) | .key' \
    "$REPO_ROOT/.github/workflows/checks.yml")"
  {
    # One file per call: yq separates multiple documents with `---`.
    for f in checks unit; do
      yq -r '.jobs[].steps[]?
        | select((.run? // "") | test("run-script.sh|run-consumer-or.sh"))
        | ((.env.SCRIPT_NAME // "") + "\t" + (.if // ""))' \
        "$REPO_ROOT/.github/workflows/$f.yml"
    done | while IFS=$'\t' read -r name cond; do
      [ -n "$name" ] || continue
      skip_this=false
      while read -r opt; do
        [ -n "$opt" ] || continue
        case "$cond" in *"inputs.$opt"*) skip_this=true ;; esac
      done <<<"$optional"
      [ "$skip_this" = true ] || printf '%s\n' "$name"
    done
    # run-consumer-or.sh takes the name as a positional argument, not env. Its
    # five steps are all gated on inputs that default to true.
    grep -oE "run-consumer-or\.sh\" '[^']+'" "$REPO_ROOT/.github/workflows/checks.yml" |
      sed "s/.*'\\(.*\\)'/\\1/"
  } | grep -v '^$' | grep -v '\${{' | sort -u
}

# Every target reachable from `make TARGET` in the consumer, following
# prerequisites transitively. Parsed rather than executed: running `make` here
# would run the gates themselves.
make_reachable() {
  MAKE_START="$1" node -e '
const fs = require("node:fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const deps = new Map();
for (const line of src.split("\n")) {
  // `target: dep dep ## description` - recipe lines are indented, so a
  // leading-space line is never a rule.
  const m = /^([A-Za-z0-9_-]+):([^=]*)$/.exec(line);
  if (!m) continue;
  const rhs = m[2].split("##")[0].trim();
  deps.set(m[1], rhs ? rhs.split(/\s+/) : []);
}
const seen = new Set();
const walk = (t) => {
  if (seen.has(t)) return;
  seen.add(t);
  for (const d of deps.get(t) || []) walk(d);
};
walk(process.env.MAKE_START);
console.log([...seen].join("\n"));
' "$CONSUMER/Makefile"
}

# The recipe text of every target reachable from `make TARGET`, so a script
# name can be looked for in what those recipes actually run.
make_recipes() {
  MAKE_TARGETS="$(make_reachable "$1" | tr '\n' ' ')" node -e '
const fs = require("node:fs");
const want = new Set(process.env.MAKE_TARGETS.trim().split(/\s+/));
const out = [];
let current = null;
for (const line of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
  const m = /^([A-Za-z0-9_-]+):([^=]*)$/.exec(line);
  if (m) { current = m[1]; continue; }
  if (current && /^\s/.test(line) && want.has(current)) out.push(line);
}
console.log(out.join("\n"));
' "$CONSUMER/Makefile"
}

@test "every script CI runs is reachable from the consumer's make ci" {
  require_consumer
  command -v yq >/dev/null || skip "yq not installed"
  [ -f "$CONSUMER/Makefile" ] || parity_skip "no Makefile at $CONSUMER - cannot compare the two gate sets"

  names="$(ci_script_names)"
  [ "$(grep -c . <<<"$names")" -ge 10 ] \
    || fail "parsed only '$names' from the workflow YAML - has the step shape changed?"

  recipes="$(make_recipes ci)"
  [ -n "$recipes" ] || fail "parsed no recipe lines from $CONSUMER/Makefile's ci target"

  targets="$(make_reachable ci)"
  missing=()
  while read -r name; do
    [ -n "$name" ] || continue
    # Three ways a CI script can be reachable locally:
    #   1. a recipe runs it by name          (`pnpm typecheck`)
    #   2. a recipe runs its dashed spelling  (rare, but cheap to allow)
    #   3. it maps onto a make target of the dashed name, which is how the
    #      make-wrapping scripts work: `check:release` is `make check-release`,
    #      whose recipe mentions neither spelling.
    alt="${name//:/-}"
    grep -qF -- "$name" <<<"$recipes" && continue
    grep -qF -- "$alt" <<<"$recipes" && continue
    grep -qxF -- "$alt" <<<"$targets" && continue
    missing+=("$name")
  done <<<"$names"

  [ "${#missing[@]}" -eq 0 ] || fail "CI runs these, and \`make ci\` in $CONSUMER does not reach them: ${missing[*]}
This is the drift the gate inventory exists to stop: a gate CI makes that a
developer cannot run locally with one command."
}

@test "every gate the consumer's make check runs has a CI step" {
  require_consumer
  command -v yq >/dev/null || skip "yq not installed"
  [ -f "$CONSUMER/Makefile" ] || parity_skip "no Makefile at $CONSUMER - cannot compare the two gate sets"

  # The direction that would have caught all four orphans. Each entry is a
  # marker that appears in a `make check` recipe, paired with the CI script name
  # that must exist for it. A gate added to `make check` with no CI step is the
  # failure being prevented, so a new row here is part of adding a gate.
  recipes="$(make_recipes check)"
  names="$(ci_script_names)"
  for pair in \
    'pnpm typecheck|typecheck' \
    'pnpm lint|lint' \
    'pnpm format:check|format:check' \
    'pnpm spell|spell' \
    'pnpm i18n:check|i18n:check' \
    'pnpm codegen:check|codegen:check' \
    'pnpm deps:check|deps:check' \
    'pnpm deps:audit|deps:audit' \
    'pnpm deps:licenses|deps:licenses' \
    'check-docs|check:docs' \
    'check-ci|check:ci' \
    'check-release|check:release'; do
    marker="${pair%%|*}"
    script="${pair##*|}"
    if grep -qF -- "$marker" <<<"$recipes"; then
      grep -qxF "$script" <<<"$names" \
        || fail "\`make check\` runs '$marker' but no CI step calls '$script' - that gate would run on developer machines and nowhere else"
    fi
  done
}

# Every script name any CI step can run, opt-in steps included: the names the
# steps spell out, the defaults of the `*-script` inputs the unit workflow
# spells them through, and the run-consumer-or.sh names.
all_ci_script_names() {
  local f
  {
    for f in checks unit; do
      yq -r '.jobs[].steps[]?
        | select((.run? // "") | test("run-script.sh|run-consumer-or.sh"))
        | (.env.SCRIPT_NAME // "")' "$REPO_ROOT/.github/workflows/$f.yml"
      yq -r '.on.workflow_call.inputs | to_entries[]
        | select(.key | test("-script$")) | .value.default' "$REPO_ROOT/.github/workflows/$f.yml"
    done
    grep -oE "run-consumer-or\.sh\" '[^']+'" "$REPO_ROOT/.github/workflows/checks.yml" |
      sed "s/.*'\\(.*\\)'/\\1/"
  } | grep -v '^$' | grep -v '\${{' | sort -u
}

# The recipe lines of one make target, and only that target's.
target_recipe() {
  MAKE_TARGET="$1" node -e '
const fs = require("node:fs");
let current = null;
for (const line of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
  const m = /^([A-Za-z0-9_-]+):([^=]*)$/.exec(line);
  if (m) { current = m[1]; continue; }
  if (current === process.env.MAKE_TARGET && /^\s/.test(line)) console.log(line);
}
' "$CONSUMER/Makefile"
}

# The generic form of the case above, which checks a hand-kept list of markers
# and so could only catch the orphans someone thought to list. The template's
# skills tests and its empty-coverage check both ran in `make ci` and in no CI
# job, and neither was on the list. Here every target `make ci` reaches that
# has a recipe of its own must be one CI runs: by name (`check-docs` is
# `check:docs`), or because every pnpm script its recipe runs is one CI runs.
@test "every target make ci reaches with a recipe of its own is run by some CI step" {
  require_consumer
  command -v yq >/dev/null || skip "yq not installed"
  [ -f "$CONSUMER/Makefile" ] || parity_skip "no Makefile at $CONSUMER - cannot compare the two gate sets"

  names="$(all_ci_script_names)"
  [ "$(grep -c . <<<"$names")" -ge 10 ] \
    || fail "parsed only '$names' from the workflow YAML - has the step shape changed?"
  dashed="$(tr ':' '-' <<<"$names")"

  orphans=()
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    recipe="$(target_recipe "$target")"
    # An aggregate (`check: check-code check-gen ...`) has no recipe; each of
    # its prerequisites is visited on its own.
    [ -n "$recipe" ] || continue
    grep -qxF -- "$target" <<<"$dashed" && continue
    scripts="$(grep -oE 'pnpm (run )?[A-Za-z0-9:_-]+' <<<"$recipe" | awk '{print $NF}')"
    if [ -z "$scripts" ]; then
      orphans+=("$target")
      continue
    fi
    while IFS= read -r s; do
      grep -qxF -- "$s" <<<"$names" || orphans+=("$target (pnpm $s)")
    done <<<"$scripts"
  done < <(make_reachable ci)

  [ "${#orphans[@]}" -eq 0 ] || fail "\`make ci\` in $CONSUMER runs these, and no CI step does: ${orphans[*]}
Fold the gate into a script CI already runs, or give it a CI step."
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
