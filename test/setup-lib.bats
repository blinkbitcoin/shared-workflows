#!/usr/bin/env bats
# scripts/setup/lib.sh - the helpers every machine setup script sources.
# Sourcing it sets SETUP_ROOT to the working directory (the app being set up,
# never the script's own location, which is node_modules/ in a consumer),
# loads the pins from scripts/lib/versions.sh beside it and defaults
# SETUP_RETRY_DELAY. Then it offers step, ok, info, warn, die, have, os,
# retry, consent, set_env_local, sha_ok, use_mise_env and parse_common_args.
#
# Also the sandbox's fakes: each a link to one dispatcher that logs and runs
# the fake's body. Covers every way out of each: the pins from this repository's layout and the
# package's; the retry delay's default and override; retry succeeding at once,
# after a failure (with its growing pause) and giving up; consent from
# SETUP_YES, refused off a terminal, and a yes, a spelled-out yes and a no on
# one; set_env_local creating the file and replacing a key; sha_ok matching and
# not; use_mise_env without mise and with it; parse_common_args with each flag,
# none, and an unknown one.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper
load setup_helper

setup() {
  setup_sandbox
}

# Runs SNIPPET in a fresh strict bash that has sourced this repository's lib.sh.
in_lib() {
  run bash -c 'set -euo pipefail; source "$REPO_ROOT/scripts/setup/lib.sh"; eval "$1"' _ "$1"
}

# The sandbox's own contract (test/setup_helper.bash): every fake is a link to
# the one dispatcher, so no test writes a fresh executable per fake - on macOS
# each one's first run is checked serially across the machine - and a fake
# still logs its call and runs its body under its own name.
@test "every fake on PATH is a link to the one dispatcher, and logs and runs its body" {
  local tool
  for tool in $FAKE_TOOLS; do
    [ -L "$FAKEBIN/$tool" ] || fail "$tool is not a link"
    [ "$(readlink "$FAKEBIN/$tool")" = "$REPO_ROOT/test/fixtures/fake-tool" ] || fail "$tool links to $(readlink "$FAKEBIN/$tool")"
  done
  [ -x "$REPO_ROOT/test/fixtures/fake-tool" ] || fail "the dispatcher is not executable"
  run uname -m
  [ "$output" = arm64 ] || fail "uname -m: $output"
  [ "$(cat "$LOG")" = "uname -m" ] || fail "log: $(cat "$LOG")"
}

@test "SETUP_ROOT is the working directory, not where the script lives, and is exported" {
  in_lib 'printf "%s\n" "$SETUP_ROOT"; bash -c "printf \"%s\n\" \"\$SETUP_ROOT\""'
  [ "$status" -eq 0 ] || fail "sourcing failed: $output"
  [ "${lines[0]}" = "$APP" ] || fail "SETUP_ROOT: ${lines[0]}"
  [ "${lines[1]}" = "$APP" ] || fail "not exported: ${lines[1]}"
}

@test "the pins come from scripts/lib/versions.sh beside it" {
  in_lib 'echo "$SETUP_ANDROID_AVD_NAME $COCOAPODS_VERSION $ANDROID_CMDLINE_TOOLS_BUILD"'
  [ "$status" -eq 0 ] || fail "sourcing failed: $output"
  local want
  want="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; echo "$SETUP_ANDROID_AVD_NAME $COCOAPODS_VERSION $ANDROID_CMDLINE_TOOLS_BUILD"')"
  [ "$output" = "$want" ] || fail "pins: $output, want $want"
}

@test "the package's layout finds the pins at ../lib/versions.sh too" {
  tooling_copy package
  set_pin COCOAPODS_VERSION 9.9.9
  run bash -c 'set -euo pipefail; source "$1"; echo "$COCOAPODS_VERSION"' _ "$COPY_SETUP/lib.sh"
  [ "$status" -eq 0 ] || fail "sourcing the package layout failed: $output"
  [ "$output" = 9.9.9 ] || fail "not the package's versions.sh: $output"
}

@test "SETUP_RETRY_DELAY defaults to five seconds and a set value is kept" {
  unset SETUP_RETRY_DELAY
  in_lib 'echo "$SETUP_RETRY_DELAY"'
  [ "$output" = 5 ] || fail "default: $output"
  SETUP_RETRY_DELAY=7 in_lib 'echo "$SETUP_RETRY_DELAY"'
  [ "$output" = 7 ] || fail "override: $output"
}

@test "step, ok and info print to stdout; warn and die to stderr, and die exits 1" {
  in_lib 'step "a step"; ok "fine"; info "note"; warn "careful" 2>/dev/null'
  [ "$status" -eq 0 ] || fail "failed: $output"
  [ "$output" = "
==> a step
  ok    fine
  ..    note" ] || fail "stdout: $output"
  in_lib 'warn "careful" 2>&1 >/dev/null'
  [ "$output" = "  warn  careful" ] || fail "warn is not on stderr: $output"
  in_lib 'die "broken" 2>&1 >/dev/null; echo "not reached"'
  [ "$status" -eq 1 ] || fail "die exited $status"
  [ "$output" = "  FAIL  broken" ] || fail "die: $output"
}

@test "have tells an installed command from a missing one" {
  in_lib 'have mise && ! have no-such-tool && echo yes'
  [ "$output" = yes ] || fail "have: $output"
}

@test "os is uname -s in lower case" {
  FAKE_OS=Linux in_lib 'os'
  [ "$output" = linux ] || fail "os: $output"
}

@test "retry runs a command that succeeds once, without a pause" {
  in_lib 'retry 3 true && echo done'
  [ "$output" = done ] || fail "retry: $output"
  [ -z "$(calls sleep)" ] || fail "paused: $(calls sleep)"
}

@test "retry pauses longer after each failure and stops at the first success" {
  SETUP_RETRY_DELAY=2 in_lib 'tries=0; flaky() { tries=$((tries + 1)); [ "$tries" -ge 3 ]; }; retry 3 flaky && echo "done after $tries"'
  [ "$status" -eq 0 ] || fail "failed: $output"
  contains "$output" "attempt 1 of 3 failed, retrying in 2s: flaky" || fail "first warning: $output"
  contains "$output" "attempt 2 of 3 failed, retrying in 4s: flaky" || fail "second warning: $output"
  contains "$output" "done after 3" || fail "not retried to success: $output"
  [ "$(calls sleep | tr '\n' ' ')" = "sleep 2 sleep 4 " ] || fail "pauses: $(calls sleep)"
}

@test "retry gives up after the last attempt and returns 1" {
  in_lib 'retry 2 false || echo "returned $?"'
  contains "$output" "gave up after 2 attempts: false" || fail "no give-up warning: $output"
  contains "$output" "returned 1" || fail "did not return 1: $output"
}

@test "consent is given by SETUP_YES=1 without asking" {
  SETUP_YES=1 in_lib 'consent "Install things" && echo agreed'
  [ "$output" = agreed ] || fail "consent: $output"
}

@test "consent off a terminal refuses and says how to agree" {
  in_lib 'consent "Install things" </dev/null; echo "not reached"'
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "not confirmed: Install things. Re-run with --yes (or SETUP_YES=1)" || fail "message: $output"
  not_contains "$output" "not reached" || fail "carried on: $output"
}

@test "consent on a terminal asks, and y or yes is a yes" {
  local answer
  for answer in y yes; do
    in_terminal "$answer" -c 'source "$REPO_ROOT/scripts/setup/lib.sh"; consent "Install things" && echo AGREED'
    [ "$status" -eq 0 ] || fail "$answer: exited $status: $output"
    contains "$output" "??    Install things [y/N]" || fail "$answer: not asked: $output"
    contains "$output" "AGREED" || fail "$answer: not agreed: $output"
  done
}

@test "consent on a terminal takes anything but a yes as a no" {
  in_terminal n -c 'source "$REPO_ROOT/scripts/setup/lib.sh"; consent "Install things"; echo AGREED'
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "not confirmed: Install things" || fail "message: $output"
  not_contains "$output" "AGREED" || fail "carried on: $output"
}

@test "set_env_local creates .env.local in the app, then replaces a key and keeps the rest" {
  in_lib 'set_env_local ANDROID_HOME /first'
  [ "$(cat "$APP/.env.local")" = "ANDROID_HOME=/first" ] || fail "created: $(cat "$APP/.env.local")"
  printf 'OTHER=kept\nANDROID_HOME=/first\n' >"$APP/.env.local"
  in_lib 'set_env_local ANDROID_HOME /second'
  [ "$(cat "$APP/.env.local")" = "OTHER=kept
ANDROID_HOME=/second" ] || fail "replaced: $(cat "$APP/.env.local")"
}

@test "sha_ok passes the expected checksum and warns on any other" {
  printf 'bytes\n' >"$WORK/file"
  local sum
  sum="$(sha_of 256 "$WORK/file")"
  in_lib "sha_ok 256 $sum \"$WORK/file\" && echo match"
  [ "$output" = match ] || fail "match: $output"
  in_lib "sha_ok 256 0000 \"$WORK/file\" || echo \"returned \$?\""
  contains "$output" "checksum mismatch for $WORK/file: expected 0000, got $sum" || fail "mismatch: $output"
  contains "$output" "returned 1" || fail "did not return 1: $output"
}

@test "use_mise_env without mise names the script that installs it" {
  rm "$FAKEBIN/mise"
  in_lib 'use_mise_env; echo "not reached"'
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "mise is not installed. Run: bash node_modules/@blinkbitcoin/app-tooling/setup/toolchain.sh" \
    || fail "message: $output"
}

@test "use_mise_env loads mise's environment for the app, whatever directory it is called from" {
  printf 'ANDROID_HOME=/from-env-local\n' >"$APP/.env.local"
  in_lib 'cd /; use_mise_env; echo "$ANDROID_HOME"'
  [ "$status" -eq 0 ] || fail "failed: $output"
  [ "$output" = /from-env-local ] || fail "not mise's environment: $output"
  contains "$(calls mise)" "mise env --shell bash" || fail "mise env not called: $(calls mise)"
}

@test "parse_common_args sets and exports SETUP_YES and SETUP_BOOT from their flags" {
  in_lib 'parse_common_args --yes --boot; bash -c "echo \$SETUP_YES \$SETUP_BOOT"'
  [ "$output" = "1 1" ] || fail "--yes --boot: $output"
  in_lib 'parse_common_args -y; bash -c "echo \$SETUP_YES \$SETUP_BOOT"'
  [ "$output" = "1 0" ] || fail "-y: $output"
  in_lib 'parse_common_args; echo "${SETUP_YES:-unset} $SETUP_BOOT"'
  [ "$output" = "unset 0" ] || fail "no flags: $output"
}

@test "parse_common_args refuses an unknown flag instead of ignoring it" {
  in_lib 'parse_common_args --yess; echo "not reached"'
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "unknown argument: --yess (known: --yes, --boot)" || fail "message: $output"
}
