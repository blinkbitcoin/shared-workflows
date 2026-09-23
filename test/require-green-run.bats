#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# `gh` is stubbed with a script that emits the next line of a canned response
# file on each call, so a multi-poll sequence (queued -> in_progress -> success)
# is exercised without a network or a real 30s sleep.
setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  RESPONSES="$BATS_TEST_TMPDIR/responses"
  COUNTER="$BATS_TEST_TMPDIR/counter"
  printf '0\n' > "$COUNTER"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
# A dispatch prints nothing and consumes no canned response.
if [ "$1" = "workflow" ] && [ "$2" = "run" ]; then exit 0; fi
n=$(cat "$WORKFLOWS_TEST_COUNTER")
n=$((n + 1))
printf '%s\n' "$n" > "$WORKFLOWS_TEST_COUNTER"
line=$(sed -n "${n}p" "$WORKFLOWS_TEST_RESPONSES")
[ -n "$line" ] || line=$(tail -1 "$WORKFLOWS_TEST_RESPONSES")
printf '%s\n' "$line"
SH
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH"
  export WORKFLOWS_TEST_RESPONSES="$RESPONSES" WORKFLOWS_TEST_COUNTER="$COUNTER" WORKFLOWS_TEST_CALLS="$CALLS"
  export WORKFLOWS_GREEN_POLL_SECONDS=0
  unset GITHUB_OUTPUT
}

green() { run bash "$REPO_ROOT/scripts/release/require-green-run.sh" cd-internal.yml abc123; }

@test "a completed successful run passes immediately" {
  printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":11}]' > "$RESPONSES"
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "run 11 for abc123 succeeded" || fail "unexpected message: $output"
}

@test "polls while the run is still going, then passes" {
  {
    printf '%s\n' '[{"conclusion":null,"status":"queued","databaseId":11}]'
    printf '%s\n' '[{"conclusion":null,"status":"in_progress","databaseId":11}]'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":11}]'
  } > "$RESPONSES"
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "is queued" || fail "did not report the queued poll: $output"
  contains "$output" "is in_progress" || fail "did not report the in_progress poll: $output"
  contains "$output" "succeeded" || fail "did not report success: $output"
}

@test "a failed run is fatal" {
  printf '%s\n' '[{"conclusion":"failure","status":"completed","databaseId":12}]' > "$RESPONSES"
  green
  [ "$status" -ne 0 ] || fail "passed on a failed run: $output"
  contains "$output" "concluded 'failure'" || fail "unexpected message: $output"
}

@test "a cancelled run is fatal" {
  printf '%s\n' '[{"conclusion":"cancelled","status":"completed","databaseId":13}]' > "$RESPONSES"
  green
  [ "$status" -ne 0 ] || fail "passed on a cancelled run: $output"
  contains "$output" "concluded 'cancelled'" || fail "unexpected message: $output"
}

@test "a skipped run is fatal - nothing verified the commit" {
  printf '%s\n' '[{"conclusion":"skipped","status":"completed","databaseId":14}]' > "$RESPONSES"
  green
  [ "$status" -ne 0 ] || fail "passed on a skipped run: $output"
  contains "$output" "was skipped" || fail "unexpected message: $output"
}

@test "no run at all within the discovery window is fatal" {
  printf '%s\n' '[]' > "$RESPONSES"
  WORKFLOWS_GREEN_DISCOVERY_MINUTES=0 green
  [ "$status" -ne 0 ] || fail "passed with no run at all: $output"
  contains "$output" "no cd-internal.yml run found for abc123" || fail "unexpected message: $output"
}

@test "an unfinished run past the overall timeout is fatal" {
  printf '%s\n' '[{"conclusion":null,"status":"in_progress","databaseId":15}]' > "$RESPONSES"
  WORKFLOWS_GREEN_TIMEOUT_MINUTES=0 green
  [ "$status" -ne 0 ] || fail "passed past the timeout: $output"
  contains "$output" "did not complete for abc123" || fail "unexpected message: $output"
}

@test "writes the run id to GITHUB_OUTPUT" {
  printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":99}]' > "$RESPONSES"
  out="$BATS_TEST_TMPDIR/gh_output"
  : > "$out"
  GITHUB_OUTPUT="$out" green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q '^run-id=99$' "$out" || fail "no run-id=99 in: $(cat "$out")"
}

# --- self-heal: REQUIRE_GREEN_DISPATCH_REF ---------------------------------
# With a dispatch ref, a missing, cancelled or failed run is dispatched once at
# that ref and the gate waits for the run the dispatch creates. The poll must
# not keep reading the replaced run as the newest one.

dispatched_once_at() {
  [ "$(grep -c '^workflow run cd-internal.yml --ref ' "$CALLS")" -eq 1 ] \
    || fail "expected exactly one dispatch, calls were: $(cat "$CALLS")"
  grep -q "^workflow run cd-internal.yml --ref $1\$" "$CALLS" \
    || fail "dispatch was not at $1: $(cat "$CALLS")"
}

@test "a cancelled run is dispatched at the ref, and the new run is waited for" {
  {
    printf '%s\n' '[{"conclusion":"cancelled","status":"completed","databaseId":20}]'
    printf '%s\n' '[{"conclusion":"cancelled","status":"completed","databaseId":20}]'
    printf '%s\n' '[{"conclusion":null,"status":"in_progress","databaseId":21}]'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":21}]'
  } > "$RESPONSES"
  REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  dispatched_once_at v1.2.3
  contains "$output" "dispatching cd-internal.yml at v1.2.3" || fail "did not say it dispatched: $output"
  contains "$output" "run 21 for abc123 succeeded" || fail "did not wait for the dispatched run: $output"
}

@test "a failed run is dispatched too" {
  {
    printf '%s\n' '[{"conclusion":"failure","status":"completed","databaseId":30}]'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":31}]'
  } > "$RESPONSES"
  REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  dispatched_once_at v1.2.3
}

@test "no run at all is dispatched once the discovery window closes" {
  {
    printf '%s\n' '[]'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":40}]'
  } > "$RESPONSES"
  WORKFLOWS_GREEN_DISCOVERY_MINUTES=0 REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  dispatched_once_at v1.2.3
  contains "$output" "run 40 for abc123 succeeded" || fail "did not wait for the dispatched run: $output"
}

@test "a dispatched run that also fails is fatal - never dispatched twice" {
  {
    printf '%s\n' '[{"conclusion":"cancelled","status":"completed","databaseId":50}]'
    printf '%s\n' '[{"conclusion":"failure","status":"completed","databaseId":51}]'
  } > "$RESPONSES"
  REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -ne 0 ] || fail "passed after the dispatched run failed: $output"
  dispatched_once_at v1.2.3
  contains "$output" "already dispatched once" || fail "unexpected message: $output"
  contains "$output" "concluded 'failure' - refusing to continue" || fail "unexpected message: $output"
}

@test "a skipped run is never dispatched" {
  printf '%s\n' '[{"conclusion":"skipped","status":"completed","databaseId":60}]' > "$RESPONSES"
  REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -ne 0 ] || fail "passed on a skipped run: $output"
  [ "$(grep -c '^workflow run' "$CALLS")" -eq 0 ] || fail "dispatched a skipped commit: $(cat "$CALLS")"
}

@test "without a dispatch ref a cancelled run stays fatal and nothing is dispatched" {
  printf '%s\n' '[{"conclusion":"cancelled","status":"completed","databaseId":70}]' > "$RESPONSES"
  green
  [ "$status" -ne 0 ] || fail "passed on a cancelled run: $output"
  [ "$(grep -c '^workflow run' "$CALLS")" -eq 0 ] || fail "dispatched without a ref: $(cat "$CALLS")"
}
