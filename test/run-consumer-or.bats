#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# run-consumer-or.sh decides which implementation of a gate runs: the consumer's
# own package script, or this repo's fallback. Five checks.yml steps go through
# it, and the reason they do is that the two implementations had already drifted
# - CI's expo-doctor.sh skipped the `expo install --check` half of the
# template's deps:check, and CI's audit.sh skipped its lockfile check, so both
# ran on laptops and in no CI job.
load test_helper

setup() {
  # consumer_root() is GITHUB_WORKSPACE + WORKING_DIRECTORY.
  ROOT="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$ROOT"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" WORKING_DIRECTORY=consumer
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_ENV GITHUB_OUTPUT
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  PATH="$STUB:$PATH"
  export PATH
  # `pnpm run NAME` is what run-script.sh execs; the stub records the call so a
  # test can tell the consumer's script ran without installing anything.
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "pnpm $*" >> "$WORKFLOWS_TEST_LOG"
exit "${WORKFLOWS_TEST_PNPM_EXIT:-0}"
SH
  chmod +x "$STUB/pnpm"
  export WORKFLOWS_TEST_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$WORKFLOWS_TEST_LOG"
}

# A consumer package.json with the given script names.
write_package_json() {
  local scripts="" name
  for name in "$@"; do
    scripts="$scripts\"$name\": \"echo ran\","
  done
  printf '{"name":"c","scripts":{%s"_":"_"}}\n' "$scripts" > "$ROOT/package.json"
}

# A throwaway fallback inside the repo tree, so the path check passes and the
# call is observable. Removed by teardown.
FALLBACK_REL="test/fixtures/run-consumer-or-fallback.sh"
write_fallback() {
  cat > "$REPO_ROOT/$FALLBACK_REL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "fallback ran" >> "$WORKFLOWS_TEST_LOG"
SH
}
teardown() { rm -f "$REPO_ROOT/$FALLBACK_REL"; }

run_it() {
  run bash "$REPO_ROOT/scripts/checks/run-consumer-or.sh" "$1" "${2:-$FALLBACK_REL}"
}

@test "the consumer's own script wins when it ships one" {
  write_package_json 'deps:audit'
  write_fallback
  run_it 'deps:audit'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q '^pnpm run deps:audit$' "$WORKFLOWS_TEST_LOG" || fail "the consumer's script did not run: $(cat "$WORKFLOWS_TEST_LOG")"
  ! grep -q 'fallback ran' "$WORKFLOWS_TEST_LOG" || fail "the fallback ran as well: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "the fallback runs when the consumer ships no such script" {
  write_package_json 'something:else'
  write_fallback
  run_it 'deps:audit'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q 'fallback ran' "$WORKFLOWS_TEST_LOG" || fail "the fallback did not run: $(cat "$WORKFLOWS_TEST_LOG")"
  ! grep -q 'pnpm run' "$WORKFLOWS_TEST_LOG" || fail "it ran a consumer script that does not exist"
}

@test "a consumer with no package.json at all gets the fallback, not a crash" {
  write_fallback
  run_it 'deps:audit'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q 'fallback ran' "$WORKFLOWS_TEST_LOG" || fail "the fallback did not run: $(cat "$WORKFLOWS_TEST_LOG")"
}

@test "which implementation ran is in the log, both ways" {
  # The drift this seam exists to stop went unnoticed because no run log said
  # which of the two implementations had executed.
  write_package_json 'deps:audit'
  write_fallback
  run_it 'deps:audit'
  contains "$output" "running the consumer's own script" || fail "the consumer branch is silent: $output"
  write_package_json 'something:else'
  run_it 'deps:audit'
  contains "$output" "ships no" || fail "the fallback branch is silent: $output"
  contains "$output" "$FALLBACK_REL" || fail "the fallback branch does not name what it ran: $output"
}

@test "a failing consumer script fails the step" {
  write_package_json 'deps:audit'
  write_fallback
  WORKFLOWS_TEST_PNPM_EXIT=3 run_it 'deps:audit'
  [ "$status" -ne 0 ] || fail "a failing gate reported success: $output"
}

@test "a missing fallback is fatal even when the consumer's script would win" {
  # A typo in a workflow's fallback path must fail on every consumer, not only
  # on the ones that happen to lack the script and so are the only ones that
  # would ever reach it.
  write_package_json 'deps:audit'
  run_it 'deps:audit' 'scripts/checks/does-not-exist.sh'
  [ "$status" -ne 0 ] || fail "accepted a fallback that does not exist: $output"
  contains "$output" "no fallback script" || fail "unexpected message: $output"
}

@test "both arguments are required" {
  run bash "$REPO_ROOT/scripts/checks/run-consumer-or.sh"
  [ "$status" -ne 0 ] || fail "accepted no arguments: $output"
  run bash "$REPO_ROOT/scripts/checks/run-consumer-or.sh" 'deps:audit'
  [ "$status" -ne 0 ] || fail "accepted a missing fallback argument: $output"
}

# The five steps this seam was built for. Named explicitly: the whole point is
# that these particular gates stop being implemented twice, and a step quietly
# reverting to its fallback-only form is the regression.
@test "checks.yml routes all five drifted gates through the seam" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/checks.yml"
  for pair in "i18n:check|scripts/checks/i18n.sh" \
    "codegen:check|scripts/checks/codegen.sh" \
    "deps:check|scripts/checks/expo-doctor.sh" \
    "deps:audit|scripts/checks/audit.sh" \
    "check:ci|scripts/ci/lint-ci.sh"; do
    name="${pair%%|*}"
    fallback="${pair##*|}"
    grep -qF "run-consumer-or.sh' '$name' $fallback" "$f" ||
      grep -qF "run-consumer-or.sh\" '$name' $fallback" "$f" ||
      fail "checks.yml does not route $name through run-consumer-or.sh with fallback $fallback"
    [ -f "$REPO_ROOT/$fallback" ] || fail "the fallback $fallback does not exist"
  done
}
