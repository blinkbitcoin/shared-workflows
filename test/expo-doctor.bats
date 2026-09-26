#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/expo-doctor.sh: the Expo project health check this repository
# runs for a consumer that ships no `deps:check` script of its own. It runs the
# consumer's own pinned expo-doctor (a devDependency) when there is one, and
# otherwise fetches the latest with `pnpm dlx`; its exit status is the doctor's.
#
# Covered here: both branches, a pin under dependencies rather than
# devDependencies, a consumer with no package.json, a failing doctor on each
# branch, no pnpm and no node on PATH, and a working directory that does not
# exist.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/expo-doctor.sh"

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export WORKFLOWS_TEST_CALLS="$CALLS"
}

# A pnpm that records what it was asked to do and succeeds, unless the test
# names a script that should fail.
stub_pnpm() {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
case " $* " in
  *" ${WORKFLOWS_TEST_FAILING_SCRIPT:-__none__} "*) exit 1 ;;
esac
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
}

# Prints a directory holding only bash, dirname and the named tools, for a PATH
# on which a tool installed on this machine cannot satisfy the lookup a case is
# about.
bare_path() {
  local dir="$BATS_TEST_TMPDIR/bare" tool
  mkdir -p "$dir"
  for tool in bash dirname "$@"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

@test "the expo-doctor fallback prefers the consumer's own pinned copy" {
  # `pnpm dlx expo-doctor@latest` reaches the network and can differ from the
  # version the consumer pinned; the local one wins when it exists.
  stub_pnpm
  printf '{"devDependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"
  run bash "$REPO_ROOT/scripts/checks/expo-doctor.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  not_contains "$output" "dlx" || fail "it fetched a copy despite a local one: $output"
}

@test "with no pinned copy the expo-doctor fallback fetches one" {
  stub_pnpm
  printf '{}\n' > "$CONSUMER/package.json"
  run bash "$REPO_ROOT/scripts/checks/expo-doctor.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "expo-doctor" || fail "it ran no doctor at all: $output"
}

@test "a pinned copy runs through pnpm exec, and nothing else runs" {
  stub_pnpm
  printf '{"devDependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "exec expo-doctor" ] || fail "expected exactly 'pnpm exec expo-doctor': $output"
}

@test "with no pinned copy the latest published doctor is fetched through pnpm dlx" {
  stub_pnpm
  printf '{"devDependencies":{"expo":"^55"}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "dlx expo-doctor@latest" ] || fail "expected exactly 'pnpm dlx expo-doctor@latest': $output"
}

@test "expo-doctor under dependencies rather than devDependencies is not taken as a pin" {
  stub_pnpm
  printf '{"dependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "dlx expo-doctor@latest" ] || fail "only a devDependency counts as a pin: $output"
}

@test "a consumer with no package.json falls back to the fetched doctor rather than failing" {
  stub_pnpm
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  [ "$output" = "dlx expo-doctor@latest" ] || fail "expected the fetched doctor: $output"
}

@test "a failing pinned doctor fails the gate" {
  stub_pnpm
  printf '{"devDependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"
  WORKFLOWS_TEST_FAILING_SCRIPT="expo-doctor" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a failing doctor must fail the gate: $output"
}

@test "a failing fetched doctor fails the gate" {
  stub_pnpm
  printf '{}\n' > "$CONSUMER/package.json"
  WORKFLOWS_TEST_FAILING_SCRIPT="expo-doctor@latest" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a failing doctor must fail the gate: $output"
}

@test "no pnpm on PATH names the missing command" {
  PATH="$(bare_path)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: pnpm" || fail "does not name the missing command: $output"
}

@test "no node on PATH names the missing command" {
  # Without node the pin cannot be read, and falling back to the network copy
  # would hide that; the script refuses instead.
  stub_pnpm
  PATH="$(bare_path pnpm)" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: node" || fail "does not name the missing command: $output"
  [ ! -s "$CALLS" ] || fail "a doctor ran anyway: $(cat "$CALLS")"
}

@test "a working directory that does not exist stops the gate before any doctor runs" {
  stub_pnpm
  WORKING_DIRECTORY="no-such-directory" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a gate over the wrong directory must not pass: $output"
  [ ! -s "$CALLS" ] || fail "a doctor ran anyway: $(cat "$CALLS")"
}
