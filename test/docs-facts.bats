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

@test "every marked count in the docs matches the tree" {
  local wrong="" name claimed real
  while read -r name claimed; do
    [ -n "$name" ] || continue
    real="$(real_count "$name" | tr -d ' ')"
    [ "$real" != "UNKNOWN" ] || fail "a doc marks an unknown count: $name"
    [ "$claimed" = "$real" ] || wrong="$wrong $name(doc=$claimed real=$real)"
  done <<< "$(marked_counts)"
  [ -z "$wrong" ] || fail "documented counts disagree with the tree:$wrong"
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

@test "the guide's check-code.yml job list is the job list" {
  # This is the case that would have caught the missing Contract job: it was
  # absent from the guide and from README while the workflow had eleven jobs.
  local line
  line="$(grep -A1 '^Jobs: `Changes`' "$REPO_ROOT/docs/consumer-guide.md" | tr '\n' ' ')"
  [ -n "$line" ] || fail "the guide no longer has a check-code.yml Jobs: line to check"
  local missing="" job
  while read -r job; do
    [ -n "$job" ] || continue
    contains "$line" "\`$job\`" || missing="$missing $job"
  done <<< "$(real_jobs check-code.yml)"
  [ -z "$missing" ] || fail "check-code.yml jobs missing from the guide's Jobs: line:$missing"
}

@test "README's check-code.yml table is the job list" {
  local table missing="" job
  table="$(sed -n '/^### `check-code.yml`/,/^### /p' "$REPO_ROOT/README.md")"
  [ -n "$table" ] || fail "README no longer has a check-code.yml section"
  while read -r job; do
    [ -n "$job" ] || continue
    contains "$table" "\`$job\`" || missing="$missing $job"
  done <<< "$(real_jobs check-code.yml)"
  [ -z "$missing" ] || fail "check-code.yml jobs missing from README's table:$missing"
}

@test "README's own-workflow table names every job of self-release.yml" {
  # publish-dev-config was missing here - the job that serves the README's own
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

