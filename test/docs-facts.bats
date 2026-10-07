#!/usr/bin/env bats
# The facts in the docs that a machine can check, checked.
#
# Why this file exists. An audit of every doc against the tree found 23
# contradictions, and 9 of the 11 worst were counts or job-name lists - both
# derivable in one line from the repository itself. Two of the counts had
# drifted within hours of being written, and two of them ("572 tests", "531
# tests") were introduced in the same commit and never agreed with each other.
# Prose that no test reads is prose that goes stale; so the countable part of it
# stops being prose.
#
# This is the fourth meta-test here, after assertions-enforced (every assertion
# ends in `|| fail`), docs-contract (Makefile <-> AGENTS.md, both directions)
# and no-legacy-prefix (the old variable prefix stays gone - that file names it,
# and is excluded from its own search for exactly that reason; this one must not
# name it, which is how it caught this comment on the first run). Same shape: derive the
# truth, compare, and self-validate the extractor so a regex that stops matching
# cannot pass by matching nothing.

load test_helper

# A marked count is `<!--count:NAME-->123<!--/count-->`. HTML comments do not
# render, so the docs read normally. A number that is not marked is not a claim
# this file checks - which is the deliberate trade: marking one is opting in.
marked_counts() {
  # Fenced blocks are stripped first: CONTRIBUTING.md documents this very
  # syntax, and an example of how to write a claim is not itself one. Found the
  # hard way - the example's number was checked as if it were real.
  mise exec -- python3 -c "
import glob, os, re
root = os.environ['REPO_ROOT']
for f in sorted(glob.glob(os.path.join(root, '*.md')) + glob.glob(os.path.join(root, 'docs/*.md'))):
    text = re.sub(r'^\`\`\`.*?^\`\`\`', '', open(f).read(), flags=re.S | re.M)
    for name, value in re.findall(r'<!--count:([a-z-]+)-->([0-9]+)<!--/count-->', text):
        print(name, value)
"
}

# The real value of each countable thing. `git ls-files`, not `find`: an
# untracked scratch file must not move a documented number.
real_count() {
  case "$1" in
    # self-* excluded: the claim this number backs is about the family a
    # consumer calls, and this repository's own CI is not part of it. They are
    # `workflow_call` workflows all the same - self-ci.yml calls self-checks.yml
    # and self-unit.yml - so counting every file that says workflow_call would
    # inflate the README's hero line every time this repo splits one of its own
    # jobs into another called workflow.
    reusable-workflows) grep -l 'workflow_call' "$REPO_ROOT"/.github/workflows/*.yml \
                          | grep -vc '/self-' ;;
    workflows)          git -C "$REPO_ROOT" ls-files '.github/workflows/*.yml' | wc -l ;;
    actions)            git -C "$REPO_ROOT" ls-files '.github/actions/*/action.yml' | wc -l ;;
    shell-scripts)      git -C "$REPO_ROOT" ls-files 'scripts/**/*.sh' | wc -l ;;
    scripts)            git -C "$REPO_ROOT" ls-files 'scripts/**/*.sh' 'scripts/**/*.mjs' | wc -l ;;
    bats-files)         git -C "$REPO_ROOT" ls-files 'test/*.bats' | wc -l ;;
    # bats --count, not `grep -c '^@test'`: the grep counts a commented-out case
    # too, which is how 554 and 551 came to disagree.
    tests)              (cd "$REPO_ROOT" && bats --count test/) ;;
    *)                  echo "UNKNOWN" ;;
  esac
}

# How precisely each count is claimed. The counts ordinary PRs grow - tests,
# scripts, bats files - are claimed as a round floor ("1800+ tests"): every
# one of them in the same hero line made any two open PRs that added a test
# conflict with each other once either merged. A floor only moves when a count
# crosses the next step, so it stays true without being touched by every PR,
# and it still cannot drift more than a step. Everything else is exact.
count_step() {
  case "$1" in
    tests) echo 100 ;;
    scripts | shell-scripts | bats-files) echo 10 ;;
    *) echo 1 ;;
  esac
}

# Whether a claimed count holds for the real one: a multiple of the count's
# step, at most the real count, and less than one step below it.
count_holds() {
  local step
  step="$(count_step "$1")"
  [ $(($2 % step)) -eq 0 ] && [ "$2" -le "$3" ] && [ "$3" -lt $(($2 + step)) ]
}

@test "every marked count in the docs matches the tree" {
  local wrong="" name claimed real
  while read -r name claimed; do
    [ -n "$name" ] || continue
    real="$(real_count "$name" | tr -d ' ')"
    [ "$real" != "UNKNOWN" ] || fail "a doc marks an unknown count: $name"
    count_holds "$name" "$claimed" "$real" || wrong="$wrong $name(doc=$claimed real=$real step=$(count_step "$name"))"
  done <<< "$(marked_counts)"
  [ -z "$wrong" ] || fail "documented counts disagree with the tree:$wrong"
}

@test "a floor holds within one step of the real count, and an exact count only at it" {
  count_holds tests 1800 1848 || fail "1800 should hold for 1848 tests"
  count_holds tests 1800 1800 || fail "1800 should hold for exactly 1800 tests"
  ! count_holds tests 1848 1848 || fail "a floor must be round: 1848 is not a multiple of 100"
  ! count_holds tests 1700 1848 || fail "1700 is more than a step stale for 1848 tests"
  ! count_holds tests 1900 1848 || fail "1900 claims more tests than there are"
  count_holds scripts 140 142 || fail "140 should hold for 142 scripts"
  ! count_holds scripts 130 142 || fail "130 is more than a step stale for 142 scripts"
  count_holds workflows 29 29 || fail "an exact count holds at its value"
  ! count_holds workflows 28 29 || fail "an exact count must not hold one below"
}

@test "the counts this repo cares about are actually marked somewhere" {
  # Without this, deleting a marker would silence the case above rather than
  # fail it - the "passes by checking nothing" shape this suite is careful of.
  local missing="" name
  for name in reusable-workflows scripts tests bats-files; do
    marked_counts | grep -q "^$name " || missing="$missing $name"
  done
  [ -z "$missing" ] || fail "no doc marks these counts any more:$missing"
}

@test "a marker inside a code fence is an example, not a claim" {
  # CONTRIBUTING.md shows the syntax in a fenced block. Counting that example
  # made its illustrative number a thing the repository had to match.
  local claims
  claims="$(marked_counts)"
  [ -n "$claims" ] || fail "the extractor found no claims at all"
  # The example in CONTRIBUTING.md is deliberately a number the tree will never
  # have; if fences were scanned, it would show up here.
  local n
  n="$(printf '%s\n' "$claims" | grep -c '^tests ' || true)"
  [ "$n" -le 2 ] || fail "a fenced example is being counted as a claim ($n 'tests' claims found)"
}

@test "the count extractor finds a marker and ignores a bare number" {
  local tmp="$BATS_TEST_TMPDIR/doc.md"
  printf 'we have <!--count:scripts-->7<!--/count--> scripts and 99 bananas\n' > "$tmp"
  run grep -ohE '<!--count:[a-z-]+-->[0-9]+<!--/count-->' "$tmp"
  contains "$output" "count:scripts-->7" || fail "did not find the marker: $output"
  not_contains "$output" "99" || fail "a bare number was treated as a claim: $output"
}

# --- job lists -----------------------------------------------------------

# Every job name a workflow really declares, one per line.
real_jobs() {
  mise exec -- yq -r '.jobs | to_entries[] | (.value.name // .key)' "$REPO_ROOT/.github/workflows/$1"
}

@test "the guide's check.yml job list is the job list" {
  # This is the case that would have caught the missing Contract job: it was
  # absent from the guide and from README while the workflow had eleven jobs.
  local line
  line="$(grep -A1 '^Jobs: `Changes`' "$REPO_ROOT/docs/consumer-guide.md" | tr '\n' ' ')"
  [ -n "$line" ] || fail "the guide no longer has a check.yml Jobs: line to check"
  local missing="" job
  while read -r job; do
    [ -n "$job" ] || continue
    contains "$line" "\`$job\`" || missing="$missing $job"
  done <<< "$(real_jobs check.yml)"
  [ -z "$missing" ] || fail "check.yml jobs missing from the guide's Jobs: line:$missing"
}

@test "README's check.yml table is the job list" {
  local table missing="" job
  table="$(sed -n '/^### `check.yml`/,/^### /p' "$REPO_ROOT/README.md")"
  [ -n "$table" ] || fail "README no longer has a check.yml section"
  while read -r job; do
    [ -n "$job" ] || continue
    contains "$table" "\`$job\`" || missing="$missing $job"
  done <<< "$(real_jobs check.yml)"
  [ -z "$missing" ] || fail "check.yml jobs missing from README's table:$missing"
}

@test "README's own-workflow table names every job of self-release.yml" {
  # publish-app-tooling was missing here - the job that serves the README's own
  # "one npm package" claim.
  local table missing="" job
  table="$(sed -n '/^### This repo.s own/,/^## /p' "$REPO_ROOT/README.md")"
  [ -n "$table" ] || fail "README no longer has a 'This repo's own' section"
  while read -r job; do
    [ -n "$job" ] || continue
    contains "$table" "\`$job\`" || missing="$missing $job"
  done <<< "$(real_jobs self-release.yml)"
  [ -z "$missing" ] || fail "self-release.yml jobs missing from README:$missing"
}

@test "the job extractor reads a name, and falls back to the job id" {
  local tmp="$BATS_TEST_TMPDIR/wf.yml"
  printf 'jobs:\n  first:\n    name: Pretty Name\n  second:\n    runs-on: x\n' > "$tmp"
  run mise exec -- yq -r '.jobs | to_entries[] | (.value.name // .key)' "$tmp"
  contains "$output" "Pretty Name" || fail "$output"
  contains "$output" "second" || fail "a job with no name must fall back to its id: $output"
}

# --- third-party action pins --------------------------------------------

@test "every third-party action version named in the docs is the pinned one" {
  # actions/create-github-app-token was @v3 in both workflows while the guide
  # said @v2, twice - a copy-pasteable version string in the contract document.
  run node -e '
    const fs = require("fs"), path = require("path");
    const root = process.env.REPO_ROOT;
    const wfDir = path.join(root, ".github/workflows");
    const real = new Map();
    for (const f of fs.readdirSync(wfDir)) {
      const text = fs.readFileSync(path.join(wfDir, f), "utf8");
      for (const [, action, ver] of text.matchAll(/uses:\s+([a-z0-9-]+\/[A-Za-z0-9._-]+)@(v[0-9]+)/g)) {
        if (!real.has(action)) real.set(action, new Set());
        real.get(action).add(ver);
      }
    }
    const docs = ["README.md", "AGENTS.md", "CONTRIBUTING.md"]
      .concat(fs.readdirSync(path.join(root, "docs")).filter((f) => f.endsWith(".md")).map((f) => `docs/${f}`));
    const wrong = [];
    for (const rel of docs) {
      const text = fs.readFileSync(path.join(root, rel), "utf8");
      for (const [, action, ver] of text.matchAll(/`([a-z0-9-]+\/[A-Za-z0-9._-]+)@(v[0-9]+)`/g)) {
        const pinned = real.get(action);
        if (pinned && !pinned.has(ver)) {
          wrong.push(`${rel} says ${action}@${ver}, the workflows pin ${[...pinned].join("/")}`);
        }
      }
    }
    if (wrong.length > 0) throw new Error(wrong.join("; "));
  '
  [ "$status" -eq 0 ] || fail "$output"
}


# --- layout ----------------------------------------------------------------

# The directories a layout has to describe: every tracked top-level directory,
# and one level down where the tree is split by area (`.github/`, `scripts/`).
# Under `.github/` only the workflows and the composite actions are this
# repository's code; the rest (issue templates, Dependabot) is GitHub's own
# configuration. `.claude-plugin/` is only the marketplace for `plugins/`, and
# is described in the plugin's row. `git ls-files`, so an untracked scratch directory does not
# demand a row.
layout_directories() {
  git -C "$REPO_ROOT" ls-files | awk -F/ '
    NF < 2 { next }
    $1 == ".github" { if ($2 == "workflows" || $2 == "actions") print $1 "/" $2 "/"; next }
    $1 == "scripts" { if (NF > 2) print $1 "/" $2 "/"; next }
    $1 == ".claude-plugin" { next }
    { print $1 "/" }
  ' | sort -u
}

# README's layout table: the path in each row's first cell.
readme_layout_paths() {
  sed -n '/^## Repository layout/,/^## /p' "$REPO_ROOT/README.md" \
    | sed -nE 's/^\| `([^`]+)`.*/\1/p'
}

# AGENTS.md's layout block: the path at the start of each line in the fence.
agents_layout_paths() {
  sed -n '/^## Layout/,/^## /p' "$REPO_ROOT/AGENTS.md" \
    | sed -n '/^```/,/^```/p' | sed -nE 's/^([^ `][^ ]*\/).*/\1/p'
}

# Prints each directory no listed path covers. A row covers a directory when it
# is the directory or lies inside it (`packages/app-tooling/` covers
# `packages/`, `deploy/ota/` covers `deploy/`).
uncovered_directories() {
  local listed="$1" dir path covered
  while read -r dir; do
    covered=""
    while read -r path; do
      case "$path" in "$dir"*) covered=1; break ;; esac
    done <<< "$listed"
    [ -n "$covered" ] || printf '%s\n' "$dir"
  done <<< "$(layout_directories)"
}

@test "README's layout table has a row for every directory" {
  # plugins/, deploy/ota/, scripts/security/ and scripts/setup/ all landed
  # without one, and the table went on reading as the whole repository.
  local listed missing
  listed="$(readme_layout_paths)"
  [ -n "$listed" ] || fail "README no longer has a Repository layout table to check"
  missing="$(uncovered_directories "$listed")"
  [ -z "$missing" ] || fail "directories missing from README's layout table: $(echo $missing)"
}

@test "AGENTS.md's layout block has a line for every directory" {
  local listed missing
  listed="$(agents_layout_paths)"
  [ -n "$listed" ] || fail "AGENTS.md no longer has a Layout block to check"
  missing="$(uncovered_directories "$listed")"
  [ -z "$missing" ] || fail "directories missing from AGENTS.md's layout: $(echo $missing)"
}

@test "the layout check names a directory nothing covers, and accepts a nested row" {
  # Self-validation: a check that cannot fail would pass on an empty table.
  local missing
  missing="$(uncovered_directories 'scripts/ci/')"
  contains "$missing" "scripts/release/" || fail "an unlisted directory was not reported: $missing"
  not_contains "$missing" "scripts/ci/" || fail "a listed directory was reported: $missing"
  missing="$(uncovered_directories 'packages/app-tooling/')"
  not_contains "$missing" "packages/" || fail "a nested row did not cover its parent: $missing"
}

@test "README's layout extractors read a path from a row and from a line" {
  local tmp="$BATS_TEST_TMPDIR/README.md"
  printf '## Repository layout\n\n| Path | What |\n| --- | --- |\n| `deploy/ota/` | x |\n\n## Next\n' > "$tmp"
  run env REPO_ROOT="$BATS_TEST_TMPDIR" bash -c "$(declare -f readme_layout_paths); readme_layout_paths"
  [ "$output" = "deploy/ota/" ] || fail "the row's path was not read: $output"
  printf '## Layout\n\n```\ndeploy/ota/   x\n              continued\n```\n\n## Next\n' > "$BATS_TEST_TMPDIR/AGENTS.md"
  run env REPO_ROOT="$BATS_TEST_TMPDIR" bash -c "$(declare -f agents_layout_paths); agents_layout_paths"
  [ "$output" = "deploy/ota/" ] || fail "the line's path was not read, or a continuation was: $output"
}

@test "README links every page under docs/" {
  # release-runbook, ota, security and decisions/ moved here with no link from
  # README's Documentation section.
  local missing="" page
  while read -r page; do
    [ -n "$page" ] || continue
    grep -qF "($page)" "$REPO_ROOT/README.md" || missing="$missing $page"
  done <<< "$(git -C "$REPO_ROOT" ls-files 'docs/*.md' 'docs/decisions/README.md' | grep -E '^docs/([^/]+|decisions/README)\.md$')"
  [ -z "$missing" ] || fail "README does not link these docs:$missing"
}

# .mise.toml and lefthook.yml both say this repository ships no package.json, and
# their reasoning (pnpm and the hook tools come from mise) rests on it. A stray
# `npm init` stub at the root once contradicted both.
@test "the repository root has no package.json, as .mise.toml and lefthook.yml say" {
  [ ! -e "$REPO_ROOT/package.json" ] || fail "a package.json is back at the root: $(head -3 "$REPO_ROOT/package.json")"
  grep -q "ships no package.json" "$REPO_ROOT/.mise.toml" || fail ".mise.toml no longer says it; update this test with it"
}
