#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/lib/e2e-ios.sh: the iOS simulator part of the E2E env contract.
# Covered here: workflows_ios_unified_log_predicate with the app id and scheme,
# with neither, and with the stack unable to answer but WORKFLOWS_APP_ID set;
# workflows_sim_udid from WORKFLOWS_SIM_UDID, from the recorded pick, and with
# no simulator picked; and that sourcing it creates nothing.
#
# ios-simulator.sh `record start|stop` also streams the simulator's unified log
# next to the video. It exists because a deep link that reached the app ~40s
# late could only be *inferred* from Maestro screenshots; SpringBoard's alert
# lifecycle and FrontBoard's UIOpenURLAction hand-off are what actually
# explain it, and they live in this log. What is here is the filter that
# decides what the log keeps; starting and stopping the stream is
# ios-simulator.sh's, in ios-simulator.bats.
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  # The Expo stack: these cases read the Expo configuration's identifiers.
  export WORKFLOWS_NATIVE_STACK_INPUT=expo
  export GITHUB_ENV="$BATS_TEST_TMPDIR/ghenv"
  : > "$GITHUB_ENV"
  mkdir -p "$WORKFLOWS_OUT"
  export WORKFLOWS_APP_ID=com.example.app
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json"
  printf '{"name":"App","scheme":"myapp","ios":{"bundleIdentifier":"com.example.app"}}\n' > "$EXPO_CONFIG_JSON"
  unset WORKFLOWS_SIM_UDID
}

# ios_env COMMANDS - runs COMMANDS in a fresh bash that has sourced common.sh
# and this library.
ios_env() {
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/e2e-ios.sh"; eval "$2"' _ "$REPO_ROOT" "$1"
}

# --- workflows_ios_unified_log_predicate -------------------------------------

@test "the predicate names the app id and scheme and the SpringBoard alert categories" {
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-ios.sh'; workflows_ios_unified_log_predicate"
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" 'eventMessage CONTAINS "com.example.app"' || fail "no app id: $output"
  contains "$output" 'eventMessage CONTAINS "myapp://"' || fail "no scheme: $output"
  contains "$output" 'category == "AlertItems"' || fail "no alert category: $output"
  contains "$output" 'category == "SceneClient"' || fail "no scene-action category: $output"
}

@test "with no app id and no scheme the predicate keeps only the system clauses" {
  unset WORKFLOWS_APP_ID
  ios_env 'workflows_app_id() { return 1; }; workflows_scheme() { return 1; }; workflows_ios_unified_log_predicate'
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ "$output" = '(process == "SpringBoard" AND (category == "AlertItems" OR category == "AlertItemStack" OR category == "SceneDeactivation")) OR (subsystem == "com.apple.FrontBoard" AND category == "SceneClient")' ] \
    || fail "got: $output"
}

@test "when the stack cannot answer, WORKFLOWS_APP_ID still narrows the predicate" {
  ios_env 'workflows_app_id() { return 1; }; workflows_scheme() { printf "\n"; }; workflows_ios_unified_log_predicate'
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" 'eventMessage CONTAINS "com.example.app"' || fail "no app id: $output"
  not_contains "$output" '://' || fail "an empty scheme was added: $output"
}

# --- workflows_sim_udid -------------------------------------------------------

@test "WORKFLOWS_SIM_UDID wins over the recorded pick" {
  printf 'PICKED-1\n' > "$WORKFLOWS_OUT/sim-udid"
  WORKFLOWS_SIM_UDID=SET-1 ios_env 'workflows_sim_udid'
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ "$output" = "SET-1" ] || fail "got '$output'"
}

@test "without WORKFLOWS_SIM_UDID the simulator ios-simulator.sh picked is used" {
  printf 'PICKED-1\n' > "$WORKFLOWS_OUT/sim-udid"
  ios_env 'workflows_sim_udid'
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  [ "$output" = "PICKED-1" ] || fail "got '$output'"
}

@test "with no simulator picked the caller is told to pick one" {
  run bash -c 'set -euo pipefail
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/e2e-ios.sh"
    udid="$(workflows_sim_udid)"
    echo "reached with udid=$udid"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ] || fail "no pick answered: $output"
  contains "$output" "no simulator selected - run ios-simulator.sh pick first" || fail "output: $output"
  not_contains "$output" "reached with" || fail "the caller carried on: $output"
}

@test "sourcing it creates nothing and publishes nothing" {
  rm -rf "$WORKFLOWS_OUT"
  ios_env 'true'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -e "$WORKFLOWS_OUT" ] || fail "sourcing the library created $WORKFLOWS_OUT"
  [ ! -s "$GITHUB_ENV" ] || fail "sourcing the library published: $(cat "$GITHUB_ENV")"
}
