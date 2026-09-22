#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# The small scripts nothing ran. None of them is complicated; that is precisely
# why they went untested, and why a wrong answer from one is hard to spot. A
# step timeout that computes the wrong bound either kills a healthy suite or
# never bounds a hung one; an env-publish that stops publishing makes a later
# `path:` resolve to nothing and an upload silently find no files; a hook runner
# that treats a missing hook as "nothing to do" skips the consumer's setup and
# fails the suite somewhere else entirely.

load test_helper

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"
  export GITHUB_OUTPUT GITHUB_ENV
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
}

# --- step-timeout --------------------------------------------------------

@test "the step bound is the suite bound plus the margin" {
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=20 WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES=5 \
    run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "minutes=25" ] || fail "wrong bound: $output"
}

@test "the step bound defaults leave room for teardown" {
  # The step must outlast the suite, or a suite that hits its own bound is
  # killed by the step first and its forensics never run.
  run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "minutes=15" ] || fail "expected the 10+5 default: $output"
}

@test "a non-numeric timeout is refused rather than read as zero" {
  # Bash reads 'abc' as 0 in arithmetic, which would publish a bound of 5 and
  # kill every suite. Both variables are checked.
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=abc run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -ne 0 ] || fail "must refuse a non-numeric suite timeout: $output"
  contains "$output" "WORKFLOWS_SUITE_TIMEOUT_MINUTES" || fail "$output"

  WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES=-1 run bash "$REPO_ROOT/scripts/e2e/step-timeout.sh"
  [ "$status" -ne 0 ] || fail "must refuse a negative margin: $output"
  contains "$output" "WORKFLOWS_STEP_TIMEOUT_MARGIN_MINUTES" || fail "$output"
}

# --- run-hook ------------------------------------------------------------

@test "an empty HOOK is a no-op, and says so" {
  HOOK="" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 0 ] || fail "an absent hook is not an error: $output"
  contains "$output" "nothing to run" || fail "$output"
}

@test "a hook that exists runs, from the consumer root" {
  mkdir -p "$CONSUMER/scripts/e2e"
  printf '#!/usr/bin/env bash\nprintf "hook ran in %%s\\n" "$PWD"\n' > "$CONSUMER/scripts/e2e/up.sh"
  chmod +x "$CONSUMER/scripts/e2e/up.sh"
  HOOK="scripts/e2e/up.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "hook ran in" || fail "the hook did not run: $output"
  contains "$output" "consumer" || fail "the hook did not run from the consumer root: $output"
}

@test "a HOOK naming a file that does not exist is fatal" {
  # Deliberately fatal: a silently skipped setup hook produces a confusing
  # suite failure later, somewhere unrelated.
  HOOK="scripts/e2e/missing.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -ne 0 ] || fail "a missing hook must not be skipped: $output"
  contains "$output" "missing.sh" || fail "does not name the path: $output"
}

@test "a hook that fails fails the step" {
  mkdir -p "$CONSUMER/scripts/e2e"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$CONSUMER/scripts/e2e/bad.sh"
  chmod +x "$CONSUMER/scripts/e2e/bad.sh"
  HOOK="scripts/e2e/bad.sh" run bash "$REPO_ROOT/scripts/e2e/run-hook.sh"
  [ "$status" -ne 0 ] || fail "a failing hook must not report success: $output"
}

# --- env-publish (both) --------------------------------------------------

@test "the e2e env-publish puts the output dir and run start in the environment" {
  # It exists so a later `with:` block can use ${{ env.WORKFLOWS_OUT }} before any
  # other script in the family has run. If it stops publishing, those resolve
  # to empty and an upload silently finds nothing.
  run bash "$REPO_ROOT/scripts/e2e/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKFLOWS_OUT=" || fail "$output"
  contains "$output" "WORKFLOWS_RUN_START=" || fail "$output"
}

@test "the release env-publish puts every release directory in the environment" {
  run bash "$REPO_ROOT/scripts/release/env-publish.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  for name in WORKFLOWS_OUT WORKFLOWS_OUTPUT_DIR WORKFLOWS_RELEASE_META_DIR WORKFLOWS_OTA_DIR WORKFLOWS_ASSETS_DIR; do
    contains "$output" "$name=" || fail "$name was not published: $output"
  done
}

@test "the release directories sit under the output dir, not the consumer tree" {
  # A release directory inside the checkout would be collected by the
  # consumer's own tooling and show up as untracked files.
  bash "$REPO_ROOT/scripts/release/env-publish.sh"
  run cat "$GITHUB_ENV"
  not_contains "$output" "=$CONSUMER" || fail "a release dir is inside the consumer checkout: $output"
}

# --- check-versions ------------------------------------------------------

@test "the version agreement gate fails when a pin drifts" {
  # It runs as a gate in `make check`, so a break is loud - but nothing asserted
  # that it *fails* when versions disagree, which is its only real behaviour.
  local work="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$work"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/.github" "$REPO_ROOT/packages" "$work/"
  cp "$REPO_ROOT/.mise.toml" "$work/"
  run mise exec -- bash "$work/scripts/self/check-versions.sh"
  [ "$status" -eq 0 ] || fail "the unmodified tree must pass: $output"

  sed -i.bak 's/^export YQ_VERSION=.*/export YQ_VERSION="0.0.0"/' "$work/scripts/lib/versions.sh"
  run mise exec -- bash "$work/scripts/self/check-versions.sh"
  [ "$status" -ne 0 ] || fail "a drifted yq pin must fail the gate: $output"
  contains "$output" "yq" || fail "does not name the drifted tool: $output"
}
