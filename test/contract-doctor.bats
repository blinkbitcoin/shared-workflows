#!/usr/bin/env bats
# The consumer-contract checker, end to end, and the shape of the job that runs
# it. The unit-level behaviour lives in
# packages/dev-config/check-consumer-contract.test.mjs (node:test); what is here
# is what only a real checkout and the real workflow file can answer.

load test_helper

DOCTOR="$REPO_ROOT/packages/dev-config/bin/check-consumer-contract.mjs"
# Exported, not just set: the two workflow-shape cases below read it from
# node's process.env. Set in the file body so it is there for every case.
CHECKS="$REPO_ROOT/.github/workflows/check-code.yml"
export CHECKS

setup() {
  TMP="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$TMP/.github/workflows"
}

# Write a caller that uses exactly the named reusable workflows.
write_caller() {
  {
    printf 'name: CI\non: [push]\njobs:\n'
    local i=0
    for workflow in "$@"; do
      i=$((i + 1))
      printf '  job%s:\n    name: Job%s\n    uses: blinkbitcoin/shared-workflows/.github/workflows/%s@v0\n' "$i" "$i" "$workflow"
    done
  } > "$TMP/.github/workflows/ci.yml"
}

@test "a repository that satisfies nothing is told everything at once, not one thing at a time" {
  write_caller check-code.yml check-unit.yml
  printf '{"name":"app"}\n' > "$TMP/package.json"

  run node "$DOCTOR" --root "$TMP"
  [ "$status" -eq 1 ] || fail "expected a failing exit, got $status"

  # The point of the whole exercise: one report naming every blocked item.
  for want in typecheck format:check spell check:docs deps:licenses test:coverage .mise.toml pnpm-lock.yaml; do
    contains "$output" "$want" || fail "the report never mentions $want: $output"
  done
  # ...and it does not stop at the first one.
  local blocked
  blocked=$(printf '%s\n' "$output" | grep -c '^FAIL' || true)
  [ "$blocked" -ge 8 ] || fail "expected every blocked item in one run, got $blocked"
}

@test "every finding names what to do about it" {
  write_caller check-code.yml
  printf '{"name":"app"}\n' > "$TMP/package.json"
  run node "$DOCTOR" --root "$TMP"
  while IFS= read -r line; do
    case "$line" in
      FAIL*|warn*) contains "$line" "Fix: " || fail "a finding with no fix: $line" ;;
    esac
  done <<< "$output"
}

@test "a workflow the repository does not call produces no findings" {
  # A repo that only runs Checks must never be told it is missing .maestro/ or a
  # Fastfile. Being wrong in this direction is what makes a report ignorable.
  write_caller check-code.yml
  printf '{"name":"app"}\n' > "$TMP/package.json"
  run node "$DOCTOR" --root "$TMP"
  not_contains "$output" ".maestro" || fail "e2e findings leaked into a checks-only repo: $output"
  not_contains "$output" "Fastfile" || fail "release findings leaked into a checks-only repo: $output"
}

@test "a gate the caller switched off is not reported against it" {
  {
    printf 'name: CI\non: [push]\njobs:\n  checks:\n    name: Checks\n'
    printf '    uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n'
    printf '    with:\n      docs-check: false\n      licenses: false\n'
  } > "$TMP/.github/workflows/ci.yml"
  printf '{"name":"app"}\n' > "$TMP/package.json"

  run node "$DOCTOR" --root "$TMP"
  not_contains "$output" "check:docs" || fail "docs-check is off but was still reported: $output"
  not_contains "$output" "deps:licenses" || fail "licenses is off but was still reported: $output"
}

@test "a missing fallback gate degrades and does not block" {
  write_caller check-code.yml
  cat > "$TMP/package.json" <<'JSON'
{
  "name": "app",
  "scripts": {
    "typecheck": "tsc", "lint": "eslint .", "format:check": "biome check",
    "spell": "typos", "check:docs": "true", "deps:licenses": "true"
  },
  "devDependencies": { "knip": "^6", "@commitlint/cli": "^19" }
}
JSON
  printf '[tools]\nnode = "24"\npnpm = "12"\n' > "$TMP/.mise.toml"
  : > "$TMP/pnpm-lock.yaml"

  run node "$DOCTOR" --root "$TMP"
  # deps:check, deps:audit and check:ci are all absent, and all have fallbacks.
  [ "$status" -eq 0 ] || fail "fallback-only gaps must not block a run: $output"
  contains "$output" "warn  deps:audit" || fail "a taken fallback must still be reported: $output"
}

@test "the job summary is written when the runner provides one" {
  write_caller check-code.yml
  printf '{"name":"app"}\n' > "$TMP/package.json"
  local summary="$BATS_TEST_TMPDIR/summary.md"
  : > "$summary"

  GITHUB_STEP_SUMMARY="$summary" run node "$DOCTOR" --root "$TMP"
  run cat "$summary"
  contains "$output" "## Consumer contract" || fail "no summary heading: $output"
  contains "$output" "**blocked**" || fail "the summary does not mark blocked rows: $output"
  contains "$output" "consumer-guide.md#" || fail "the summary does not link the contract: $output"
}

@test "--json reports every requirement with its level" {
  write_caller check-code.yml
  printf '{"name":"app"}\n' > "$TMP/package.json"
  # stdout only: the ::error:: annotation goes to stderr, and a consumer piping
  # this into jq must get JSON and nothing else.
  node "$DOCTOR" --root "$TMP" --json > "$BATS_TEST_TMPDIR/out.json" 2>/dev/null || true
  F="$BATS_TEST_TMPDIR/out.json" run node -e '
    const rows = JSON.parse(require("fs").readFileSync(process.env.F, "utf8"));
    if (!rows.every((r) => r.id && r.level)) throw new Error("a row with no id or level");
    if (!rows.some((r) => r.level === "fail")) throw new Error("no failure reported");
  '
  [ "$status" -eq 0 ] || fail "--json is not machine-readable: $output"
}

@test "the checker needs nothing but node: no pnpm, no yq, no node_modules" {
  # It runs before the setup action on purpose - a consumer whose toolchain is
  # the thing that is missing must still get a report. Anything it shells out to
  # would be a tool the failing repository may not have.
  run grep -nE "(child_process|execSync|spawnSync)" "$DOCTOR"
  [ "$status" -ne 0 ] || fail "the checker shells out, so it cannot run before setup: $output"
}

@test "the contract job carries no job-level if:, so turning the check off cannot skip the workflow" {
  # Every other job needs: contract. A job whose dependency was *skipped* is
  # skipped too, and a skipped job counts as passing for a required check - so
  # an `if:` on this job would turn `contract-check: false` into a silently
  # green Checks run with no gates at all.
  run node -e '
    const text = require("fs").readFileSync(process.env.CHECKS, "utf8");
    const job = text.split(/^  contract:$/m)[1].split(/^  [a-z][a-z0-9-]*:$/m)[0];
    const lines = job.split("\n").filter((l) => /^    if:/.test(l));
    if (lines.length > 0) throw new Error(`contract job has a job-level if: ${lines.join(" ")}`);
    if (!/if: \$\{\{ inputs\.contract-check \}\}/.test(job)) throw new Error("the toggle does not gate the step");
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "every gate job in check-code.yml waits for the contract job" {
  # The whole value is that one explanatory red replaces nine confusing ones.
  # A gate job that does not wait still produces its own.
  run node -e '
    const text = require("fs").readFileSync(process.env.CHECKS, "utf8");
    const names = [...text.matchAll(/^  ([a-z][a-z0-9-]*):$/gm)].map((m) => m[1]);
    const exempt = new Set(["contract", "changes"]);
    const missing = names.filter((name) => {
      if (exempt.has(name)) return false;
      const body = text.split(new RegExp(`^  ${name}:$`, "m"))[1].split(/^  [a-z][a-z0-9-]*:$/m)[0];
      return !/^    needs: contract$/m.test(body);
    });
    if (missing.length > 0) throw new Error(`jobs that do not wait for the contract job: ${missing.join(", ")}`);
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a broken package.json is an annotation, not a node stack trace" {
  # The failure this whole file exists to replace. A checker that answers a
  # malformed package.json with a SyntaxError and eight frames of node internals
  # is no better than the gate it runs ahead of.
  write_caller check-code.yml
  printf '{ "name": "x",, }' > "$TMP/package.json"
  run node "$DOCTOR" --root "$TMP"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status"
  contains "$output" "::error::" || fail "no annotation: $output"
  contains "$output" "is not valid JSON" || fail "the message does not name the problem: $output"
  not_contains "$output" "at Object." || fail "a stack trace leaked: $output"
  not_contains "$output" "node:internal" || fail "a stack trace leaked: $output"
}

@test "an unknown argument is an annotation too" {
  run node "$DOCTOR" --nope
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status"
  contains "$output" "::error::unknown argument: --nope" || fail "$output"
  not_contains "$output" "node:internal" || fail "a stack trace leaked: $output"
}

@test "a --profile that is not one is refused, not silently green" {
  # `lint` is a gate, not a profile - the plausible wrong guess, since profiles
  # are named after workflows. It matches no requirement, so every check would
  # skip and the run would end "every requirement is satisfied": a green answer
  # to a question nobody asked.
  run node "$DOCTOR" --root "$TMP" --profile lint
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status"
  contains "$output" "unknown profile(s): lint" || fail "$output"
  contains "$output" "known: " || fail "the message does not say what is valid: $output"
}

@test "the wrapper and the checker still work through a symlinked .workflows" {
  # How this was found: node resolves symlinks when it loads a module, so
  # `import.meta.url` is the real path while `process.argv[1]` is what the
  # caller typed. The `am I the program?` guard compared the two directly, and
  # through a link they differ - so the checker loaded, ran nothing, printed
  # nothing and exited 0. A gate that silently passes is worse than one that
  # fails, and this one is reached by a path a consumer may well link.
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/.github/workflows"
  printf '{"name":"app"}\n' > "$ws/package.json"
  printf 'jobs:\n  checks:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' \
    > "$ws/.github/workflows/ci.yml"
  ln -s "$REPO_ROOT" "$ws/.workflows"

  cd "$ws"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." run bash ".workflows/scripts/ci/contract-check.sh"
  [ "$status" -eq 1 ] || fail "expected the unmet contract to fail, got $status: $output"
  contains "$output" "FAIL" || fail "the checker produced no findings through a symlink: $output"
}

@test "every dev-config bin still runs when invoked through a symlink" {
  # A package manager installs a `bin` entry into node_modules/.bin as a link,
  # so `pnpm exec <bin>` - the usage the package README advertises - reaches
  # these files through one. The `am I the program?` guard compared
  # import.meta.url (real path) against argv[1] (as typed), so through a link it
  # said "imported": no output, exit 0. Verified directly: the same guard
  # answers "RAN as program" on a direct call and silently nothing on a linked
  # one. Both bins now resolve argv[1] first.
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  for f in "$REPO_ROOT"/packages/dev-config/bin/*.mjs; do
    ln -s "$f" "$bin/$(basename "$f" .mjs)"
  done

  run node "$bin/check-tool-versions" node
  contains "$output" "node" || fail "check-tool-versions printed nothing through a symlink: $output"

  run node "$bin/check-consumer-contract" --root "$TMP" --profile checks
  contains "$output" "package.json" || fail "check-consumer-contract printed nothing through a symlink: $output"
}

# --- the adoption doc ---------------------------------------------------
#
# docs/adopting-an-existing-repo.md is the page for a repository that was never
# generated from the template. Its requirement table is generated from
# contract.json rather than written, because a hand-kept adoption checklist is
# right on the day it is written and wrong six months later.

@test "the adoption doc's table is what the renderer produces from contract.json" {
  local doc="$REPO_ROOT/docs/adopting-an-existing-repo.md"
  run node "$REPO_ROOT/scripts/self/render-contract-table.mjs"
  [ "$status" -eq 0 ] || fail "the renderer failed: $output"
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/rendered.md"
  diff -u "$doc" "$BATS_TEST_TMPDIR/rendered.md" \
    || fail "the adoption doc is out of date - run: node scripts/self/render-contract-table.mjs --write"
}

@test "the adoption doc names every workflow a consumer can call" {
  # A profile added to the contract with no section here means a consumer
  # calling that workflow reads a page that silently omits its requirements.
  local doc="$REPO_ROOT/docs/adopting-an-existing-repo.md"
  run node --input-type=module -e '
    import fs from "node:fs";
    const root = process.env.REPO_ROOT;
    const { PROFILE_TITLE } = await import(`${root}/scripts/self/render-contract-table.mjs`);
    const contract = JSON.parse(fs.readFileSync(`${root}/packages/dev-config/contract.json`, "utf8"));
    const doc = fs.readFileSync(`${root}/docs/adopting-an-existing-repo.md`, "utf8");
    const used = new Set(contract.requirements.map((r) => r.profile));
    // A profile names a workflow by its title (`check-code.yml` for checks), not by itself.
    const missing = [...used].filter((p) => !doc.includes(`### If you call ${PROFILE_TITLE[p] ?? p}`));
    if (missing.length > 0) throw new Error(`no section for: ${missing.join(", ")}`);
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a contract-only run gates nothing, and says so" {
  # Opt-in and useful, but a green Checks that ran no gate is exactly the shape
  # of result someone reads as "it passed".
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/.github/workflows"
  printf '{"name":"app","scripts":{}}\n' > "$ws/package.json"
  ln -s "$REPO_ROOT" "$ws/.workflows"
  local summary="$BATS_TEST_TMPDIR/summary.md"
  : > "$summary"

  cd "$ws"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." WORKFLOWS_CONTRACT_ONLY=true \
    GITHUB_STEP_SUMMARY="$summary" run bash ".workflows/scripts/ci/contract-check.sh"
  contains "$output" "::warning::contract-only run" || fail "no warning: $output"
  contains "$output" "NO gate ran" || fail "$output"
  run cat "$summary"
  contains "$output" "Contract-only run" || fail "the summary does not say it: $output"
}

@test "contract-only is off by default, and every gate job honours it" {
  run node -e '
    const text = require("fs").readFileSync(process.env.CHECKS, "utf8");
    const block = text.split(/^      contract-only:$/m)[1].split(/^      [a-z]/m)[0];
    if (!/default: false/.test(block)) throw new Error("contract-only must default to false");
    const names = [...text.matchAll(/^  ([a-z][a-z0-9-]*):$/gm)].map((m) => m[1]);
    const exempt = new Set(["contract", "changes"]);
    const missing = names.filter((name) => {
      if (exempt.has(name)) return false;
      const body = text.split(new RegExp(`^  ${name}:$`, "m"))[1].split(/^  [a-z][a-z0-9-]*:$/m)[0];
      return !/!inputs\.contract-only/.test(body);
    });
    if (missing.length > 0) throw new Error(`gate jobs that ignore contract-only: ${missing.join(", ")}`);
  '
  [ "$status" -eq 0 ] || fail "$output"
}
