#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# A fake `gh`: `run list` prints FAKE_RUN_ID (the id the real --jq filter would
# pick) or fails with FAKE_LIST_FAILS; `run rerun` fails with FAKE_RERUN_FAILS.
# Every call is logged, so each case can assert exactly what reached GitHub.
setup() {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2" = "run list" ]; then
  if [ -n "${FAKE_LIST_FAILS:-}" ]; then echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
  printf '%s\n' "${FAKE_RUN_ID:-}"
  exit 0
fi
if [ "$1 $2" = "run rerun" ]; then
  if [ -n "${FAKE_RERUN_FAILS:-}" ]; then echo "HTTP 403: run cannot be retried" >&2; exit 1; fi
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 2
EOF
  chmod +x "$fakebin/gh"
  export PATH="$fakebin:$PATH"
  export GH_TOKEN=fake GH_REPO=org/app WORKFLOW=cd-beta.yml HEAD_SHA=deadbeef
}

@test "a blocked run for the commit gets only its failed jobs re-run" {
  FAKE_RUN_ID=4242 run bash "$REPO_ROOT/scripts/release/retry.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'run rerun 4242 --failed' "$GH_LOG" || fail "no 'gh run rerun 4242 --failed': $(cat "$GH_LOG")"
  contains "$output" "re-running the failed jobs of cd-beta.yml run 4242 (deadbeef)" || fail "output: $output"
}

@test "the listing asks for this workflow's runs at exactly this commit, and picks concluded, unsuccessful ones" {
  FAKE_RUN_ID=4242 run bash "$REPO_ROOT/scripts/release/retry.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  list="$(grep '^run list ' "$GH_LOG")"
  contains "$list" "--workflow cd-beta.yml --commit deadbeef" || fail "the listing was not scoped: $list"
  contains "$list" 'select(.status == "completed" and .conclusion != "success" and .conclusion != "skipped")' \
    || fail "the filter no longer picks concluded, unsuccessful runs: $list"
}

@test "no blocked run for the commit is not an error, and nothing is re-run" {
  FAKE_RUN_ID= run bash "$REPO_ROOT/scripts/release/retry.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "no concluded, unsuccessful cd-beta.yml run for deadbeef - nothing to retry" || fail "output: $output"
  ! grep -q '^run rerun' "$GH_LOG" || fail "something was re-run: $(cat "$GH_LOG")"
}

@test "a listing that fails fails the step, naming the repository and the likely cause" {
  FAKE_LIST_FAILS=1 run bash "$REPO_ROOT/scripts/release/retry.sh"
  [ "$status" -ne 0 ] || fail "a failed listing passed: $output"
  contains "$output" "could not list cd-beta.yml runs for deadbeef in org/app (does the job grant actions: write?)" \
    || fail "output: $output"
  contains "$output" "HTTP 403" || fail "gh's own reason was dropped: $output"
  not_contains "$output" "nothing to retry" || fail "a failed listing read as nothing to retry: $output"
}

@test "a re-run GitHub refuses fails the step" {
  FAKE_RUN_ID=4242 FAKE_RERUN_FAILS=1 run bash "$REPO_ROOT/scripts/release/retry.sh"
  [ "$status" -ne 0 ] || fail "a refused re-run passed: $output"
  contains "$output" "could not re-run the failed jobs of cd-beta.yml run 4242" || fail "output: $output"
}

@test "each required variable is named when it is missing" {
  for var in GH_TOKEN GH_REPO WORKFLOW HEAD_SHA; do
    run env -u "$var" bash "$REPO_ROOT/scripts/release/retry.sh"
    [ "$status" -ne 0 ] || fail "ran without $var: $output"
    contains "$output" "::error::missing required environment variable: $var" || fail "the missing $var was not named: $output"
  done
}
