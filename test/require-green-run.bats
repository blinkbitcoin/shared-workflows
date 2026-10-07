#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# `gh` is stubbed with a script that emits the next line of a canned response
# file on each call, so a multi-poll sequence (queued -> in_progress -> success)
# is exercised without a network or a real 30s sleep.
setup() {
  RESPONSES="$BATS_TEST_TMPDIR/responses"
  COUNTER="$BATS_TEST_TMPDIR/counter"
  printf '0\n' > "$COUNTER"
  stub_cmd gh - <<'SH'
# A dispatch prints nothing and consumes no canned response.
if [ "$1" = "workflow" ] && [ "$2" = "run" ]; then exit 0; fi
n=$(cat "$WORKFLOWS_TEST_COUNTER")
n=$((n + 1))
printf '%s\n' "$n" > "$WORKFLOWS_TEST_COUNTER"
line=$(sed -n "${n}p" "$WORKFLOWS_TEST_RESPONSES")
[ -n "$line" ] || line=$(tail -1 "$WORKFLOWS_TEST_RESPONSES")
printf '%s\n' "$line"
SH
  CALLS="$(stub_log gh)"
  export WORKFLOWS_TEST_RESPONSES="$RESPONSES" WORKFLOWS_TEST_COUNTER="$COUNTER"
  export WORKFLOWS_GREEN_POLL_SECONDS=0
  unset GITHUB_OUTPUT
}

green() { run bash "$REPO_ROOT/scripts/release/require-green-run.sh" cd-internal.yml abc123; }

@test "a completed successful run passes immediately" {
  printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":11}]' > "$RESPONSES"
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "run 11 for abc123 succeeded" || fail "unexpected message: $output"
  traced "$output" "Wait for cd-internal.yml to succeed on abc123" || fail "the wait was not timed: $output"
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

# gh_noisy STDERR [EXIT] - replace the gh stub with one that prints the next
# canned response on stdout, STDERR on stderr, and exits EXIT (default 0).
gh_noisy() {
  stub_cmd gh - <<SH
if [ "\$1" = "workflow" ] && [ "\$2" = "run" ]; then exit 0; fi
printf '%s\\n' "$1" >&2
[ "${2:-0}" -eq 0 ] && head -1 "\$WORKFLOWS_TEST_RESPONSES"
exit ${2:-0}
SH
}

# A notice on stderr from a call that succeeded used to be merged into the JSON,
# which then failed to parse and read as "no run": a green run went unseen.
@test "a notice on stderr from a successful gh call does not hide the run" {
  printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":31}]' > "$RESPONSES"
  gh_noisy 'A new release of gh is available: 2.80.0'
  green
  [ "$status" -eq 0 ] || fail "a stderr notice hid a green run: $output"
  contains "$output" "run 31 for abc123 succeeded" || fail "unexpected message: $output"
  contains "$output" "succeeded with a notice: A new release of gh is available" || fail "the notice was dropped: $output"
}

@test "a gh call that keeps failing is reported as an API problem, quoting gh's stderr" {
  printf '%s\n' '[]' > "$RESPONSES"
  gh_noisy 'HTTP 403: Resource not accessible by integration' 1
  WORKFLOWS_GREEN_DISCOVERY_MINUTES=0 green
  [ "$status" -ne 0 ] || fail "passed with every gh call failing: $output"
  contains "$output" "every 'gh run list' failed, the last with: HTTP 403: Resource not accessible by integration" \
    || fail "the failure did not quote gh: $output"
  not_contains "$output" "it was never started" || fail "an API failure was reported as a missing run: $output"
}

@test "the stderr scratch file does not survive the run" {
  printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":32}]' > "$RESPONSES"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$(ls -A "$RUNNER_TEMP")" ] || fail "left files behind: $(ls -A "$RUNNER_TEMP")"
}

# --- reading the JSON: one parse per poll ------------------------------------
# Each poll reads the run count, id, status and conclusion in a single yq call.
# These cases hold the shapes that call must split into four fields without
# shifting one into another's place, and the outputs it must read as no run.

@test "parses gh's JSON once per poll" {
  {
    printf '%s\n' '[{"conclusion":null,"status":"queued","databaseId":11}]'
    printf '%s\n' '[{"conclusion":null,"status":"in_progress","databaseId":11}]'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":11}]'
  } > "$RESPONSES"
  real_yq="$(command -v yq)" || fail "yq is not on PATH"
  stub_cmd yq "exec $(printf '%q' "$real_yq") \"\$@\""
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  polls="$(grep -c '^run list ' "$CALLS")" || fail "no gh run list call: $(cat "$CALLS")"
  parses="$(stub_calls yq | grep -c .)" || fail "yq was never called"
  [ "$polls" -eq 3 ] || fail "expected 3 polls, got $polls: $(cat "$CALLS")"
  [ "$parses" -eq "$polls" ] || fail "expected one yq call per poll ($polls), got $parses: $(stub_calls yq)"
}

@test "a run in progress has a null conclusion, and is polled, not judged" {
  {
    printf '%s\n' '[{"conclusion":null,"status":"in_progress","databaseId":16}]'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":16}]'
  } > "$RESPONSES"
  REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "run 16 is in_progress; polling again" || fail "the fields shifted or the poll was not reported: $output"
  not_contains "$output" "concluded" || fail "an unfinished run was judged: $output"
  [ "$(grep -c '^workflow run' "$CALLS")" -eq 0 ] || fail "dispatched for a run still in progress: $(cat "$CALLS")"
}

@test "no runs yet ([]) is polled while the discovery window is open" {
  {
    printf '%s\n' '[]'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":17}]'
  } > "$RESPONSES"
  REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "no cd-internal.yml run for abc123 yet" || fail "an empty list was not read as no run: $output"
  contains "$output" "run 17 for abc123 succeeded" || fail "unexpected message: $output"
  [ "$(grep -c '^workflow run' "$CALLS")" -eq 0 ] || fail "dispatched inside the discovery window: $(cat "$CALLS")"
}

@test "unparsable output from a successful gh call reads as no run, not as a gh failure" {
  printf '%s\n' '[{"conclusion":' > "$RESPONSES"
  WORKFLOWS_GREEN_DISCOVERY_MINUTES=0 green
  [ "$status" -ne 0 ] || fail "passed on unparsable output: $output"
  contains "$output" "no cd-internal.yml run found for abc123 within 0m - it was never started" \
    || fail "unparsable output was not read as no run: $output"
  not_contains "$output" "every 'gh run list' failed" || fail "unparsable output was reported as a gh failure: $output"
}

@test "unparsable output is polled again, and a later run is still seen" {
  {
    printf '%s\n' 'not: [json'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":18}]'
  } > "$RESPONSES"
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "no cd-internal.yml run for abc123 yet" || fail "unparsable output was not read as no run: $output"
  contains "$output" "run 18 for abc123 succeeded" || fail "unexpected message: $output"
}

@test "unparsable output is dispatched like no run once the discovery window closes" {
  {
    printf '%s\n' '[{"conclusion":'
    printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":19}]'
  } > "$RESPONSES"
  WORKFLOWS_GREEN_DISCOVERY_MINUTES=0 REQUIRE_GREEN_DISPATCH_REF=v1.2.3 green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  dispatched_once_at v1.2.3
  contains "$output" "run 19 for abc123 succeeded" || fail "did not wait for the dispatched run: $output"
}

@test "a successful gh call that prints nothing reads as no run" {
  printf '\n' > "$RESPONSES"
  WORKFLOWS_GREEN_DISCOVERY_MINUTES=0 green
  [ "$status" -ne 0 ] || fail "passed with no output at all: $output"
  contains "$output" "it was never started" || fail "empty output was not read as no run: $output"
  not_contains "$output" "every 'gh run list' failed" || fail "empty output was reported as a gh failure: $output"
}

@test "a missing conclusion does not shift the run id, and is fatal once completed" {
  printf '%s\n' '[{"status":"completed","databaseId":22}]' > "$RESPONSES"
  green
  [ "$status" -ne 0 ] || fail "passed with no conclusion: $output"
  contains "$output" "run 22 for abc123 concluded '' - refusing to continue" || fail "unexpected message: $output"
}

@test "a missing run id does not shift the status or conclusion" {
  printf '%s\n' '[{"conclusion":"success","status":"completed"}]' > "$RESPONSES"
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "cd-internal.yml run  for abc123 succeeded" || fail "unexpected message: $output"
}

@test "a missing status is not read as completed" {
  printf '%s\n' '[{"conclusion":"success","databaseId":23}]' > "$RESPONSES"
  WORKFLOWS_GREEN_TIMEOUT_MINUTES=0 green
  [ "$status" -ne 0 ] || fail "passed without a status: $output"
  contains "$output" "run 23 is ; polling again" || fail "the fields shifted: $output"
  contains "$output" "did not complete for abc123" || fail "unexpected message: $output"
}

@test "only the newest run is read when gh lists several" {
  printf '%s\n' '[{"conclusion":"success","status":"completed","databaseId":25},{"conclusion":"failure","status":"completed","databaseId":24}]' > "$RESPONSES"
  green
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "run 25 for abc123 succeeded" || fail "unexpected message: $output"
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
