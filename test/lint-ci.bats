#!/usr/bin/env bats
# lint-ci.sh's two halves (actionlint over .github/workflows, shellcheck over
# scripts/) must be independently reachable: a consumer with workflows but no
# scripts/ directory is a perfectly normal Expo app and must still get
# actionlint. `mise` is stubbed so these assert the branching, not the linters.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/consumer"
  export WORKING_DIRECTORY=.
  mkdir -p "$GITHUB_WORKSPACE"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  MISE_LOG="$BATS_TEST_TMPDIR/mise.log"
  export MISE_LOG
  cat > "$bin/mise" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MISE_LOG"
STUB
  chmod +x "$bin/mise"
  PATH="$bin:$PATH"
  export PATH
  : > "$MISE_LOG"
}

workflows() {
  mkdir -p "$GITHUB_WORKSPACE/.github/workflows"
  printf 'name: ci\non: push\njobs: {}\n' > "$GITHUB_WORKSPACE/.github/workflows/ci.yml"
}

scripts() {
  mkdir -p "$GITHUB_WORKSPACE/scripts"
  printf '#!/usr/bin/env bash\ntrue\n' > "$GITHUB_WORKSPACE/scripts/x.sh"
}

@test "runs actionlint even when the consumer has no scripts/ directory" {
  workflows
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep -q actionlint "$MISE_LOG"
  ! grep -q shellcheck "$MISE_LOG" || fail "shellcheck ran for a docs-only change: $(cat "$MISE_LOG")"
}

@test "runs shellcheck even when the consumer has no .github/workflows directory" {
  scripts
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep -q shellcheck "$MISE_LOG"
  ! grep -q actionlint "$MISE_LOG" || fail "actionlint ran with WORKFLOWS_ACTIONLINT off: $(cat "$MISE_LOG")"
}

@test "runs both halves when the consumer has both" {
  workflows
  scripts
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep -q actionlint "$MISE_LOG"
  grep -q shellcheck "$MISE_LOG"
}

@test "WORKFLOWS_ACTIONLINT=false disables only the actionlint half" {
  workflows
  scripts
  WORKFLOWS_ACTIONLINT=false run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  ! grep -q actionlint "$MISE_LOG" || fail "actionlint ran with no .github/workflows: $(cat "$MISE_LOG")"
  grep -q shellcheck "$MISE_LOG"
}

@test "WORKFLOWS_SHELLCHECK=false disables only the shellcheck half" {
  workflows
  scripts
  WORKFLOWS_SHELLCHECK=false run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep -q actionlint "$MISE_LOG"
  ! grep -q shellcheck "$MISE_LOG" || fail "shellcheck ran with no scripts dir: $(cat "$MISE_LOG")"
}

@test "exits 0 with nothing to lint when the consumer has neither directory" {
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to lint"* ]] || fail "assertion failed; output: $output"
  [ ! -s "$MISE_LOG" ]
}

@test "runs zizmor offline at medium severity when the consumer has workflows" {
  workflows
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  line="$(grep zizmor "$MISE_LOG")" || fail "zizmor did not run: $(cat "$MISE_LOG")"
  [[ "$line" == *"--offline"* && "$line" == *"--min-severity medium"* ]] \
    || fail "zizmor ran without the deterministic flags: $line"
}

@test "WORKFLOWS_ZIZMOR=false disables only the zizmor half" {
  workflows
  WORKFLOWS_ZIZMOR=false run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep -q actionlint "$MISE_LOG"
  ! grep -q zizmor "$MISE_LOG" || fail "zizmor ran with WORKFLOWS_ZIZMOR off: $(cat "$MISE_LOG")"
}

@test "a consumer without a zizmor config gets this family's policy" {
  workflows
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep zizmor "$MISE_LOG" | grep -qF -- "--config $REPO_ROOT/.github/zizmor.yml" \
    || fail "fallback policy not passed: $(grep zizmor "$MISE_LOG")"
}

@test "a consumer's own .github/zizmor.yml wins over the family's, passed explicitly" {
  workflows
  printf 'rules: {}\n' > "$GITHUB_WORKSPACE/.github/zizmor.yml"
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep zizmor "$MISE_LOG" | grep -qF -- "--config .github/zizmor.yml .github" \
    || fail "the consumer's own .github/zizmor.yml was not passed: $(grep zizmor "$MISE_LOG")"
}

@test "a consumer's root zizmor.yml is passed explicitly when .github/ has none" {
  workflows
  printf 'rules: {}\n' > "$GITHUB_WORKSPACE/zizmor.yml"
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep zizmor "$MISE_LOG" | grep -qF -- "--config zizmor.yml .github" \
    || fail "the consumer's root zizmor.yml was not passed: $(grep zizmor "$MISE_LOG")"
}

@test "with both, .github/zizmor.yml wins, the way zizmor's own search orders them" {
  workflows
  printf 'rules: {}\n' > "$GITHUB_WORKSPACE/zizmor.yml"
  printf 'rules: {}\n' > "$GITHUB_WORKSPACE/.github/zizmor.yml"
  run bash "$REPO_ROOT/scripts/ci/lint-ci.sh"
  [ "$status" -eq 0 ]
  grep zizmor "$MISE_LOG" | grep -qF -- "--config .github/zizmor.yml .github" \
    || fail "picked the root zizmor.yml over .github/zizmor.yml: $(grep zizmor "$MISE_LOG")"
}
