#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/e2e/maestro-suite.sh: the Maestro suite run ios-maestro.sh and
# android-maestro.sh share. prepare_maestro_suite exports the driver startup
# timeout, enters the consumer and checks the flows directory;
# run_maestro_suite builds the `maestro test` command line, bounds it, reruns
# it once unless it hung, and is green only when the junit report shows flows
# ran. maestro is a fake: it records each call with its working directory and
# driver timeout, writes a junit report with MAESTRO_TESTS flows, and exits with
# the next status in MAESTRO_STATUSES.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  export WORKFLOWS_APP_ID=com.example.app
  mkdir -p "$GITHUB_WORKSPACE/.maestro"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  cat > "$bin/maestro" <<'STUB'
#!/usr/bin/env bash
printf 'maestro %s\n' "$*" >> "$CALLS"
printf 'cwd %s timeout %s\n' "$PWD" "${MAESTRO_DRIVER_STARTUP_TIMEOUT:-unset}" >> "$CALLS"
n=$(grep -c '^maestro ' "$CALLS")
set -- "$@" ""
out=""
while [ "$#" -gt 1 ]; do [ "$1" = --output ] && out="$2"; shift; done
[ -n "$out" ] && printf '<testsuites tests="%s"/>\n' "${MAESTRO_TESTS:-3}" > "$out"
read -r -a statuses <<< "${MAESTRO_STATUSES:-0}"
exit "${statuses[$((n - 1))]:-0}"
STUB
  chmod +x "$bin/maestro"
  export PATH="$bin:/usr/bin:/bin"
}

# Runs SNIPPET in a shell that has sourced the libraries the way the platform
# scripts do, then prints `status N` for what the snippet's last call returned.
in_suite_shell() {
  run bash -c 'set -uo pipefail
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/e2e-env.sh"
source "$REPO_ROOT/scripts/e2e/maestro-suite.sh"
'"$1"
}

maestro_calls() { grep '^maestro ' "$CALLS"; }
default_call() {
  printf '%s' "maestro test .maestro --platform $1 -e APP_ID=com.example.app --debug-output $WORKFLOWS_OUT/maestro --flatten-debug-output --format junit --output $WORKFLOWS_OUT/maestro/junit.xml"
}

@test "prepare: exports the default driver timeout, enters the consumer and creates the output directory" {
  in_suite_shell 'cd /; prepare_maestro_suite; printf "pwd %s\n" "$PWD"; bash -c "printf \"exported %s\n\" \"\$MAESTRO_DRIVER_STARTUP_TIMEOUT\""'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "pwd $(cd "$GITHUB_WORKSPACE" && pwd -P)" || fail "did not enter the consumer: $output"
  contains "$output" "exported 300000" || fail "the default timeout was not exported: $output"
  [ -d "$WORKFLOWS_OUT/maestro" ] || fail "no output directory"
}

@test "prepare: an explicit driver timeout below the bound is kept" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=1000 in_suite_shell 'prepare_maestro_suite; printf "timeout %s\n" "$MAESTRO_DRIVER_STARTUP_TIMEOUT"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "timeout 1000" || fail "output: $output"
}

@test "prepare: a driver timeout at or over the suite bound exits 1 before anything else" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=600000 in_suite_shell 'prepare_maestro_suite; echo "carried on"'
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "is not below the suite bound" || fail "output: $output"
  not_contains "$output" "carried on" || fail "carried on after the bad timeout: $output"
  [ ! -d "$WORKFLOWS_OUT/maestro" ] || fail "created the output directory anyway"
}

@test "prepare: a driver timeout that is not milliseconds exits 1" {
  MAESTRO_DRIVER_STARTUP_TIMEOUT=abc in_suite_shell 'prepare_maestro_suite; echo "carried on"'
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  contains "$output" "must be milliseconds, got 'abc'" || fail "output: $output"
  not_contains "$output" "carried on" || fail "carried on after the bad timeout: $output"
}

@test "prepare: a consumer directory that cannot be entered exits 1" {
  in_suite_shell 'consumer_root() { printf "%s\n" "$BATS_TEST_TMPDIR/missing"; }; prepare_maestro_suite; echo "carried on"'
  [ "$status" -eq 1 ] || fail "expected 1, got $status: $output"
  not_contains "$output" "carried on" || fail "carried on outside the consumer: $output"
}

@test "prepare: no flows directory fails, naming it and the variable" {
  rmdir "$GITHUB_WORKSPACE/.maestro"
  in_suite_shell 'prepare_maestro_suite; echo "carried on"'
  [ "$status" -ne 0 ] || fail "passed without flows: $output"
  contains "$output" "no flows directory at $(cd "$GITHUB_WORKSPACE" && pwd -P)/.maestro (WORKFLOWS_MAESTRO_FLOWS)" || fail "output: $output"
  not_contains "$output" "carried on" || fail "carried on without flows: $output"
}

@test "prepare: honours a custom WORKFLOWS_MAESTRO_FLOWS" {
  mkdir -p "$GITHUB_WORKSPACE/e2e/flows"
  rmdir "$GITHUB_WORKSPACE/.maestro"
  WORKFLOWS_MAESTRO_FLOWS=e2e/flows in_suite_shell 'prepare_maestro_suite'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
}

@test "run: with no device arguments, the command line is the platform's and the report check names it" {
  in_suite_shell 'prepare_maestro_suite; run_maestro_suite android Android --; echo "status $?"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(maestro_calls)" = "$(default_call android)" ] || fail "maestro: $(maestro_calls)"
  contains "$output" "status 0" || fail "output: $output"
  contains "$output" "maestro test (Android, bound 10m)" || fail "the group was not named: $output"
  contains "$output" "Android: Maestro ran 3 flow(s)" || fail "output: $output"
}

@test "run: device arguments follow --platform, inside the consumer, under the exported driver timeout" {
  in_suite_shell 'prepare_maestro_suite; run_maestro_suite ios iOS --udid SIM-1 --; echo "status $?"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(maestro_calls)" = "maestro test .maestro --platform ios --udid SIM-1 -e APP_ID=com.example.app --debug-output $WORKFLOWS_OUT/maestro --flatten-debug-output --format junit --output $WORKFLOWS_OUT/maestro/junit.xml" ] \
    || fail "maestro: $(maestro_calls)"
  contains "$(cat "$CALLS")" "cwd $(cd "$GITHUB_WORKSPACE" && pwd -P) timeout 300000" || fail "calls: $(cat "$CALLS")"
  contains "$output" "iOS: Maestro ran 3 flow(s)" || fail "output: $output"
}

@test "run: the app id comes from the platform when WORKFLOWS_APP_ID is not set" {
  unset WORKFLOWS_APP_ID
  cat > "$BATS_TEST_TMPDIR/app-config.sh" <<'STUB'
workflows_app_config() { printf 'id-for-%s\n' "$1"; }
STUB
  in_suite_shell 'source "$BATS_TEST_TMPDIR/app-config.sh"; prepare_maestro_suite; run_maestro_suite android Android --'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(maestro_calls)" "-e APP_ID=id-for-android-package " || fail "maestro: $(maestro_calls)"
}

@test "run: passes the flows' config.yaml and the tag filters when there are any" {
  touch "$GITHUB_WORKSPACE/.maestro/config.yaml"
  WORKFLOWS_MAESTRO_INCLUDE_TAGS=smoke WORKFLOWS_MAESTRO_EXCLUDE_TAGS=slow \
    in_suite_shell 'prepare_maestro_suite; run_maestro_suite ios iOS --udid SIM-1 --'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(maestro_calls)" = "maestro test .maestro --platform ios --udid SIM-1 --config .maestro/config.yaml -e APP_ID=com.example.app --debug-output $WORKFLOWS_OUT/maestro --flatten-debug-output --format junit --output $WORKFLOWS_OUT/maestro/junit.xml --include-tags smoke --exclude-tags slow" ] \
    || fail "maestro: $(maestro_calls)"
}

@test "run: the caller's arguments after -- go last, a later -- included, each kept whole" {
  WORKFLOWS_MAESTRO_INCLUDE_TAGS=smoke \
    in_suite_shell 'prepare_maestro_suite; run_maestro_suite android Android -- --exclude-tags "two words" -- --last'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(maestro_calls)" = "$(default_call android) --include-tags smoke --exclude-tags two words -- --last" ] || fail "maestro: $(maestro_calls)"
  [ "$(grep -c '^maestro ' "$CALLS")" -eq 1 ] || fail "calls: $(cat "$CALLS")"
}

@test "run: the bound and its group label follow WORKFLOWS_SUITE_TIMEOUT_MINUTES" {
  WORKFLOWS_SUITE_TIMEOUT_MINUTES=7 in_suite_shell 'prepare_maestro_suite; run_maestro_suite ios iOS --'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "maestro test (iOS, bound 7m)" || fail "output: $output"
}

@test "run: a failed suite is rerun once with the same command line, and the rerun's green counts" {
  MAESTRO_STATUSES="1 0" in_suite_shell 'prepare_maestro_suite; run_maestro_suite ios iOS --udid SIM-1 --; echo "status $?"'
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(grep -c '^maestro ' "$CALLS")" -eq 2 ] || fail "calls: $(cat "$CALLS")"
  [ "$(maestro_calls | sort -u | wc -l | tr -d ' ')" -eq 1 ] || fail "the rerun changed the command line: $(maestro_calls)"
  contains "$output" "::warning::Maestro suite failed (status 1) - rerunning the suite once" || fail "output: $output"
  contains "$output" "maestro test (iOS, retry)" || fail "the retry group was not named: $output"
  contains "$output" "status 0" || fail "output: $output"
}

@test "run: a suite that fails twice returns the rerun's status, without the report check" {
  MAESTRO_STATUSES="1 2" in_suite_shell 'prepare_maestro_suite; run_maestro_suite android Android --; echo "status $?"'
  [ "$status" -eq 0 ] || fail "the snippet itself failed: $output"
  contains "$output" "status 2" || fail "expected the rerun's 2: $output"
  not_contains "$output" "Maestro ran" || fail "checked the report of a failed suite: $output"
}

@test "run: a hung suite (124) is not rerun and returns 124" {
  MAESTRO_STATUSES=124 in_suite_shell 'prepare_maestro_suite; run_maestro_suite ios iOS --; echo "status $?"'
  [ "$(grep -c '^maestro ' "$CALLS")" -eq 1 ] || fail "reran a hung suite: $(cat "$CALLS")"
  contains "$output" "status 124" || fail "output: $output"
  not_contains "$output" "rerunning" || fail "output: $output"
}

@test "run: a green suite that ran no flows exits through the report check" {
  MAESTRO_TESTS=0 in_suite_shell 'prepare_maestro_suite; run_maestro_suite android Android --; echo "status $?"'
  [ "$status" -ne 0 ] || fail "passed with no flows: $output"
  contains "$output" "Android: Maestro exited 0 but ran 0 flows" || fail "output: $output"
  not_contains "$output" "status " || fail "returned instead of exiting: $output"
}

@test "run: a rerun that goes green with no flows still fails the report check" {
  MAESTRO_STATUSES="1 0" MAESTRO_TESTS=0 in_suite_shell 'prepare_maestro_suite; run_maestro_suite ios iOS --'
  [ "$status" -ne 0 ] || fail "passed with no flows: $output"
  contains "$output" "iOS: Maestro exited 0 but ran 0 flows" || fail "output: $output"
}

@test "run: fewer than two arguments fails with the usage, before maestro" {
  in_suite_shell 'run_maestro_suite ios; echo "carried on"'
  [ "$status" -ne 0 ] || fail "passed without a display name: $output"
  contains "$output" "usage: run_maestro_suite PLATFORM DISPLAY_NAME [DEVICE_ARGUMENT...] -- [MAESTRO_TEST_ARGUMENT...]" || fail "output: $output"
  not_contains "$output" "carried on" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "maestro ran: $(cat "$CALLS")"
}

@test "run: no -- before the Maestro test arguments fails naming it, before maestro" {
  in_suite_shell 'prepare_maestro_suite; run_maestro_suite ios iOS --udid SIM-1; echo "carried on"'
  [ "$status" -ne 0 ] || fail "passed without --: $output"
  contains "$output" "run_maestro_suite: no -- before the Maestro test arguments" || fail "output: $output"
  not_contains "$output" "carried on" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "maestro ran: $(cat "$CALLS")"
}
