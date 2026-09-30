#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/expo-doctor.sh: the Expo project health check this repository
# runs for a consumer that ships no `deps:check` script of its own, and that
# @blinkbitcoin/dev-config ships for a consumer's `make check-deps`. SDK drift
# (`expo install --check`) is reported and never fails the gate; expo-doctor
# then runs with its own version check off, and its status is the gate's. The
# doctor is the consumer's pinned devDependency when there is one, and the
# latest published one through `pnpm dlx` otherwise.
#
# Covered here: the drift half with no drift, with drift (a warning counting
# the packages behind, an annotation under Actions), with a failing check that
# lists no package, and skipped with no expo dependency; both doctor branches,
# a pin under dependencies rather than devDependencies, a consumer with no
# package.json, a failing doctor on each branch and after drift, no pnpm and
# no node on PATH, and a working directory that does not exist.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/expo-doctor.sh"

DRIFT_TABLE='The following packages should be updated for best compatibility with the installed expo version:
  expo-router@6.0.1 - expected version: 6.0.2
  react-native-screens@4.1.0 - expected version: 4.1.1
Your project may not work correctly until you install the expected versions of the packages.'

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
  unset GITHUB_ACTIONS EXPO_DOCTOR_SKIP_DEPENDENCY_VERSION_CHECK
}

# A pnpm that records each call, the directory it ran in and whether doctor's
# version check was off. `exec expo install --check` prints FAKE_DRIFT_OUT and
# exits FAKE_DRIFT_STATUS; any other call succeeds unless it names
# WORKFLOWS_TEST_FAILING_SCRIPT.
stub_pnpm() {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s | %s | skip=%s\n' "$PWD" "$*" "${EXPO_DOCTOR_SKIP_DEPENDENCY_VERSION_CHECK:-unset}" >> "$WORKFLOWS_TEST_CALLS"
if [ "$*" = "exec expo install --check" ]; then
  printf '%s\n' "${FAKE_DRIFT_OUT:-Dependencies are up to date}"
  echo 'expo stderr line' >&2
  exit "${FAKE_DRIFT_STATUS:-0}"
fi
case " $* " in
  *" ${WORKFLOWS_TEST_FAILING_SCRIPT:-__none__} "*) exit "${FAKE_DOCTOR_STATUS:-1}" ;;
esac
echo "doctor ran: $*"
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
}

# calls - what pnpm was asked, without the directory and the switch.
calls() { cut -d'|' -f2 "$CALLS" | sed 's/^ //; s/ $//'; }

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

expo_app() { printf '{"dependencies":{"expo":"^55"},"devDependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"; }

@test "no drift: the check is printed, then the pinned doctor runs with its version check off, in the consumer" {
  stub_pnpm
  expo_app
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "Dependencies are up to date" || fail "the check was not printed: $output"
  contains "$output" "doctor ran: exec expo-doctor" || fail "doctor did not run: $output"
  not_contains "$output" "warning" || fail "warned with no drift: $output"
  run cat "$CALLS"
  local root
  root="$(cd "$CONSUMER" && pwd -P)"
  [ "$output" = "$root | exec expo install --check | skip=unset
$root | exec expo-doctor | skip=1" ] || fail "calls: $output"
}

@test "drift is a warning counting the packages behind, and the gate still passes" {
  stub_pnpm
  expo_app
  FAKE_DRIFT_OUT="$DRIFT_TABLE" FAKE_DRIFT_STATUS=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "drift failed the gate: $output"
  contains "$output" "expo-router@6.0.1 - expected version: 6.0.2" || fail "the table was not printed: $output"
  contains "$output" "expo stderr line" || fail "the check's stderr was not folded in: $output"
  contains "$output" "warning: Expo SDK drift: 2 package(s) behind the SDK's expected patch. Advisory" || fail "output: $output"
  not_contains "$output" "::warning" || fail "an annotation outside Actions: $output"
  [ "$(calls | tail -1)" = "exec expo-doctor" ] || fail "doctor did not run after drift: $(calls)"
}

@test "under GitHub Actions the drift is also a warning annotation" {
  stub_pnpm
  expo_app
  GITHUB_ACTIONS=true FAKE_DRIFT_OUT="$DRIFT_TABLE" FAKE_DRIFT_STATUS=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning title=Expo SDK drift::Expo SDK drift: 2 package(s) behind" || fail "output: $output"
}

@test "a failing check with no package rows still warns, counting zero, and does not fail" {
  stub_pnpm
  expo_app
  FAKE_DRIFT_OUT='fetch failed: registry unreachable' FAKE_DRIFT_STATUS=2 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "Expo SDK drift: 0 package(s) behind" || fail "output: $output"
}

@test "with no expo dependency the drift check is skipped, and doctor still runs" {
  stub_pnpm
  printf '{"devDependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "no expo dependency in package.json: the SDK drift check is skipped" || fail "output: $output"
  [ "$(calls)" = "exec expo-doctor" ] || fail "calls: $(calls)"
}

@test "expo as a devDependency is an Expo project too" {
  stub_pnpm
  printf '{"devDependencies":{"expo":"^55"}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls | head -1)" = "exec expo install --check" ] || fail "calls: $(calls)"
}

@test "with no pinned copy the latest published doctor is fetched through pnpm dlx" {
  stub_pnpm
  printf '{"dependencies":{"expo":"^55"}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls | tail -1)" = "dlx expo-doctor@latest" ] || fail "expected 'pnpm dlx expo-doctor@latest': $(calls)"
  [ "$(cut -d'|' -f3 "$CALLS" | tail -1)" = " skip=1" ] || fail "the fetched doctor ran its version check: $(cat "$CALLS")"
}

@test "expo-doctor under dependencies rather than devDependencies is not taken as a pin" {
  stub_pnpm
  printf '{"dependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls)" = "dlx expo-doctor@latest" ] || fail "only a devDependency counts as a pin: $(calls)"
}

@test "a consumer with no package.json falls back to the fetched doctor rather than failing" {
  stub_pnpm
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls)" = "dlx expo-doctor@latest" ] || fail "expected the fetched doctor: $(calls)"
}

@test "a failing pinned doctor fails the gate with its status" {
  stub_pnpm
  expo_app
  WORKFLOWS_TEST_FAILING_SCRIPT="expo-doctor" FAKE_DOCTOR_STATUS=5 run bash "$SCRIPT"
  [ "$status" -eq 5 ] || fail "expected doctor's status 5, got $status: $output"
  not_contains "$output" "warning" || fail "output: $output"
}

@test "a failing fetched doctor fails the gate" {
  stub_pnpm
  printf '{}\n' > "$CONSUMER/package.json"
  WORKFLOWS_TEST_FAILING_SCRIPT="expo-doctor@latest" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a failing doctor must fail the gate: $output"
}

@test "doctor failing after drift still fails the gate" {
  stub_pnpm
  expo_app
  WORKFLOWS_TEST_FAILING_SCRIPT="expo-doctor" FAKE_DRIFT_OUT="$DRIFT_TABLE" FAKE_DRIFT_STATUS=1 run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "Expo SDK drift: 2 package" || fail "output: $output"
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
