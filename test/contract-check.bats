#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/contract-check.sh: the Contract job's step in check-code.yml. It
# finds the dev-config checker beside itself, warns loudly on a contract-only
# run, and hands over to the checker with the consumer root and --skeleton, so
# the checker's exit code is the step's. Covered: a consumer that meets the
# contract and one that does not, the skeleton on a failure, the contract-only
# warning with and without a job summary, a working directory below the
# workspace, the path through a symlinked .workflows, and both refusals - no
# node, and no checker beside the script.
# The checker's own rules are packages/dev-config/check-consumer-contract.test.mjs
# and contract-doctor.bats.

load test_helper

SCRIPT="$REPO_ROOT/scripts/ci/contract-check.sh"

# A consumer that calls only check-code.yml and meets every requirement it has.
# The fallback-only gaps (deps:check, deps:audit, check:ci) degrade, never block.
write_passing_consumer() { # <directory>
  local dir="$1"
  mkdir -p "$dir/.github/workflows"
  printf 'jobs:\n  checks:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' \
    > "$dir/.github/workflows/ci.yml"
  cat > "$dir/package.json" <<'JSON'
{
  "name": "app",
  "scripts": {
    "typecheck": "tsc", "lint": "eslint .", "format:check": "biome check",
    "spell": "typos", "check:docs": "true", "deps:licenses": "true"
  },
  "devDependencies": { "knip": "^6", "@commitlint/cli": "^19" }
}
JSON
  printf '[tools]\nnode = "24"\npnpm = "12"\n' > "$dir/.mise.toml"
  : > "$dir/pnpm-lock.yaml"
}

# A consumer that calls check-code.yml and has nothing it needs.
write_failing_consumer() { # <directory>
  local dir="$1"
  mkdir -p "$dir/.github/workflows"
  printf '{"name":"app"}\n' > "$dir/package.json"
  printf 'jobs:\n  checks:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' \
    > "$dir/.github/workflows/ci.yml"
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

@test "a consumer that meets the contract passes, with no contract-only warning" {
  local ws="$BATS_TEST_TMPDIR/ws"
  write_passing_consumer "$ws"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a consumer meeting the contract failed: $output"
  contains "$output" "ok    typecheck" || fail "the checker's findings are missing: $output"
  not_contains "$output" "FAIL" || fail "a passing consumer has a blocked finding: $output"
  not_contains "$output" "contract-only" || fail "a normal run warned about contract-only: $output"
}

@test "an unmet contract fails the step and prints the skeleton that would clear it" {
  # --skeleton is the wrapper's to pass: the checker alone prints no skeleton.
  local ws="$BATS_TEST_TMPDIR/ws"
  write_failing_consumer "$ws"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected the checker's exit 1, got $status: $output"
  contains "$output" "Either add these to package.json:" || fail "no skeleton - was --skeleton passed? $output"
  contains "$output" "::error::consumer contract:" || fail "no annotation: $output"
}

@test "a contract-only run with no job summary warns on the log and writes no file" {
  # Outside a runner there is no GITHUB_STEP_SUMMARY; the warning must not
  # depend on one, and nothing may be written in its place.
  local ws="$BATS_TEST_TMPDIR/ws"
  write_passing_consumer "$ws"
  local before after
  cd "$ws"
  before="$(find "$BATS_TEST_TMPDIR" | sort)"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." WORKFLOWS_CONTRACT_ONLY=true run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "expected the passing consumer to pass, got $status: $output"
  contains "$output" "::warning::contract-only run: the contract was checked and NO gate ran" || fail "no warning: $output"
  after="$(find "$BATS_TEST_TMPDIR" | sort)"
  [ "$before" = "$after" ] || fail "a file was written: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
}

@test "contract-only is off unless it is exactly true" {
  local ws="$BATS_TEST_TMPDIR/ws" value
  write_passing_consumer "$ws"
  for value in false "" TRUE 1; do
    GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." WORKFLOWS_CONTRACT_ONLY="$value" run bash "$SCRIPT"
    [ "$status" -eq 0 ] || fail "WORKFLOWS_CONTRACT_ONLY='$value': expected a pass, got $status: $output"
    not_contains "$output" "contract-only" || fail "WORKFLOWS_CONTRACT_ONLY='$value' warned: $output"
  done
}

@test "the working directory, not the workspace root, is what the checker is given" {
  # A root that fails the contract with an app below it that meets it: only the
  # app's verdict may come back.
  local ws="$BATS_TEST_TMPDIR/ws"
  write_failing_consumer "$ws"
  write_passing_consumer "$ws/apps/mobile"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="apps/mobile" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "the checker was not pointed at the working directory: $output"

  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "the failing root passed: $output"
}

@test "a runner without node is refused before the checker is looked for" {
  # Only what the script needs before its node check: dirname to find common.sh.
  local only="$BATS_TEST_TMPDIR/only" ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$only"
  ln -s "$(command -v dirname)" "$only/dirname"
  write_passing_consumer "$ws"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." run env PATH="$only" "$BASH" "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: node" || fail "does not name the missing command: $output"
}

@test "a checkout without the checker beside the script is refused, naming the path" {
  # The script finds the checker two directories up from itself. A copy of the
  # script in a tree with no packages/dev-config is a checkout that lost it.
  local tree="$BATS_TEST_TMPDIR/tree" ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$tree/scripts/ci" "$tree/scripts/lib"
  cp "$SCRIPT" "$tree/scripts/ci/contract-check.sh"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$tree/scripts/lib/common.sh"
  write_passing_consumer "$ws"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="." run bash "$tree/scripts/ci/contract-check.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::contract-check.sh: no checker at $tree/packages/dev-config/bin/check-consumer-contract.mjs" ||
    fail "does not name where it looked: $output"
}
