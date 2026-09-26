#!/usr/bin/env bats
# ios-simulator.sh `record start|stop` also streams the simulator's unified log
# next to the video. It exists because a deep link that reached the app ~40s
# late could only be *inferred* from Maestro screenshots; SpringBoard's alert
# lifecycle and FrontBoard's UIOpenURLAction hand-off are what actually
# explain it, and they live in this log.
#
# What is here is the filter that decides what the log keeps:
# workflows_ios_unified_log_predicate in scripts/lib/e2e-env.sh. Starting and
# stopping the stream is ios-simulator.sh's, in ios-simulator.bats.
load test_helper

setup() {
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/ghenv"
  : > "$GITHUB_ENV"
  mkdir -p "$WORKFLOWS_OUT"
  export WORKFLOWS_APP_ID=com.example.app
  export EXPO_CONFIG_JSON="$BATS_TEST_TMPDIR/expo.json"
  printf '{"name":"App","scheme":"myapp","ios":{"bundleIdentifier":"com.example.app"}}\n' > "$EXPO_CONFIG_JSON"
}

@test "the predicate names the app id and scheme and the SpringBoard alert categories" {
  run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/lib/e2e-env.sh'; workflows_ios_unified_log_predicate"
  [ "$status" -eq 0 ] || fail "status $status; output: $output"
  contains "$output" 'eventMessage CONTAINS "com.example.app"' || fail "no app id: $output"
  contains "$output" 'eventMessage CONTAINS "myapp://"' || fail "no scheme: $output"
  contains "$output" 'category == "AlertItems"' || fail "no alert category: $output"
  contains "$output" 'category == "SceneClient"' || fail "no scene-action category: $output"
}
