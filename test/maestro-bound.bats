#!/usr/bin/env bats
load test_helper

setup() {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  # Every command under test runs with PATH=$fakebin alone: no coreutils
  # timeout, so the pure-bash watchdog is the branch under test unless a stub
  # is planted explicitly. It holds links to exactly the tools the watchdog
  # runs. It used to be "$fakebin:/usr/bin:/bin", and /usr/bin holds a timeout
  # on ubuntu, so CI tested coreutils here and never the watchdog.
  local tool
  for tool in bash sleep mktemp rm cat; do
    ln -sf "$(command -v "$tool")" "$fakebin/$tool"
  done
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$WORKFLOWS_OUT"
}

plant_timeout_stub() {
  cat > "$fakebin/timeout" <<'EOF'
#!/bin/bash
echo "STUB TIMEOUT: $*"
exit 124
EOF
  chmod +x "$fakebin/timeout"
}

@test "sourcing exposes bounded_maestro" {
  run bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; declare -F bounded_maestro"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bounded_maestro"* ]] || fail "assertion failed; output: $output"
}

@test "a fast command's exit code is propagated" {
  run bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; bounded_maestro 30 bash -c 'exit 7'"
  [ "$status" -eq 7 ]
}

@test "a fast command's success is propagated" {
  run bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; bounded_maestro 30 bash -c 'echo hi'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hi"* ]] || fail "assertion failed; output: $output"
}

@test "a slow command exits 124 via the pure-bash watchdog" {
  run bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; bounded_maestro 1 sleep 30"
  [ "$status" -eq 124 ]
  [[ "$output" == *"::error::"* ]] || fail "assertion failed; output: $output"
}

@test "coreutils timeout is used when available" {
  plant_timeout_stub
  run bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; bounded_maestro 5 sleep 30"
  [ "$status" -eq 124 ]
  [[ "$output" == *"STUB TIMEOUT"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"-k 30s 5s"* ]] || fail "assertion failed; output: $output"
}

@test "the test PATH really has no timeout, so the watchdog is what runs" {
  run bash -c "PATH='$fakebin'; command -v timeout || command -v gtimeout"
  [ "$status" -ne 0 ] || fail "a timeout is on the test PATH: $output"
}

# A killed watchdog subshell used to leave its sleep running, holding this
# function's output open: a caller reading through a pipe waited out the nap,
# thirty seconds after a timeout and one second on every normal run.
@test "after a timeout the watchdog leaves nothing holding the caller's pipe" {
  local started=$SECONDS
  out="$(bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; bounded_maestro 1 sleep 30; echo \"rc=\$?\"" 2>&1 | cat)"
  [ $((SECONDS - started)) -lt 10 ] || fail "the pipe stayed open for $((SECONDS - started))s"
  contains "$out" "rc=124" || fail "not a timeout: $out"
}

@test "a fast command returns without waiting out the watchdog's nap" {
  local started=$SECONDS i
  for i in 1 2 3 4 5; do
    bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; bounded_maestro 30 true" | cat
  done
  [ $((SECONDS - started)) -lt 3 ] || fail "five fast runs took $((SECONDS - started))s - each waited on the watchdog"
}

# The watchdog's output is /dev/null, but any other descriptor it inherits stays
# open as long as one of its naps runs - bats' own fd 3 included, which made
# this file wait half a minute after its last test. A nap that outlived the
# watchdog (the TERM landing between `sleep &` and saving its pid) did exactly
# that, so this holds a pipe open on fd 9 alone and times how long it lives.
@test "after a timeout no nap of the watchdog outlives it, on any descriptor" {
  local started=$SECONDS i
  for i in 1 2 3; do
    { bash -c "PATH='$fakebin'; . '$REPO_ROOT/scripts/e2e/maestro-bound.sh'; bounded_maestro 1 sleep 30" >/dev/null 2>&1; } 9>&1 | cat
  done
  [ $((SECONDS - started)) -lt 10 ] || fail "an inherited descriptor stayed open for $((SECONDS - started))s"
}
