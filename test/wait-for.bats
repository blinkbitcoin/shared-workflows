#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# wait_for in test_helper.bash: the poll the suite waits on a background
# process's state with. Covered: state already there, state a background
# process leaves later (the command's arguments reaching it, its failures not
# ending the test), and a deadline that passes, which fails naming what it
# waited for.
load test_helper

@test "state already there returns at once, silently" {
  : > "$BATS_TEST_TMPDIR/ready"
  run wait_for 60 "the ready file" test -f "$BATS_TEST_TMPDIR/ready"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "printed: $output"
}

@test "state a background process leaves later is waited for, and the failed checks before it do not end the test" {
  misses="$BATS_TEST_TMPDIR/misses" later="$BATS_TEST_TMPDIR/later"
  probe() { [ -f "$1" ] && return 0; printf 'miss\n' >> "$misses"; return 1; }
  # The file comes only after a check has missed it, however slowly either side
  # starts; the bound only stops a broken wait_for from leaving this behind.
  (for _ in $(seq 1 600); do [ -s "$misses" ] && break; sleep 0.1; done; : > "$later") 3>&- &
  run wait_for 60 "the later file" probe "$later"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -f "$later" ] || fail "returned before the file was there"
  [ -s "$misses" ] || fail "no check missed: the wait was never exercised"
}

@test "a deadline that passes fails, naming what it waited for and for how long" {
  checks="$BATS_TEST_TMPDIR/checks"
  probe() { printf 'check\n' >> "$checks"; return 1; }
  run wait_for 1 "a file that never comes" probe
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  [ "$output" = "gave up after 1s waiting for a file that never comes" ] || fail "output: $output"
  [ -s "$checks" ] || fail "never ran the check"
}
