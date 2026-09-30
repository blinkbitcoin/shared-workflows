#!/usr/bin/env bats
# scripts/setup/all.sh - the whole machine setup, from the app's root:
# toolchain.sh, then ci/maestro-install.sh under mise, android.sh and ios.sh,
# then the doctor under mise. The doctor is SETUP_DOCTOR when set, else
# ../bin/doctor.mjs beside setup/ (the package's layout), else
# ../../packages/app-tooling/bin/doctor.mjs (this repository's).
#
# Run against the fakes in test/setup_helper.bash, with a stub doctor. The
# real script runs where the doctor is SETUP_DOCTOR; each probe runs in a copy
# laid out as the package or as this repository, and the package copy also
# downloads Maestro through the real maestro-install.sh.
#
# Covers every way out: the order of the steps; each doctor probe, the
# package's first, and no doctor at all (refused before anything installs);
# Maestro installed into ~/.maestro; a failing step stopping the steps after
# it; the flags reaching the Android licence question; a doctor that fails;
# and a Linux machine whose mise the toolchain step just installed into
# ~/.local/bin, which the later steps still find.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper
load setup_helper

setup() {
  setup_sandbox
  SCRIPT="$REPO_ROOT/scripts/setup/all.sh"
  # Nothing to download on the real script's runs: Maestro at the pin and the
  # Android command-line tools already in the SDK.
  plant_maestro "$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; echo "$MAESTRO_VERSION"')"
  plant_cmdline_tools "$SDK"
  doctor_stub "$WORK/doctor.mjs"
}

# doctor_stub FILE: a doctor that logs where it ran, and exits FAKE_DOCTOR_STATUS.
doctor_stub() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'EOF'
import fs from 'node:fs';
fs.appendFileSync(process.env.LOG, `doctor ${process.argv[1]} in ${process.cwd()}\n`);
process.exit(Number(process.env.FAKE_DOCTOR_STATUS || 0));
EOF
}

# all ARGUMENTS...: the real script, finishing with the stub doctor.
all() { SETUP_DOCTOR="$WORK/doctor.mjs" run bash "$SCRIPT" "$@" </dev/null; }

# The steps the log shows, in order.
milestones() {
  awk '
    /^mise install --yes$/ { print "toolchain" }
    /^mise exec -- bash .*\/ci\/maestro-install\.sh$/ { print "maestro" }
    /^android .*platform-tools$/ { print "android" }
    /^xcodebuild -version$/ { print "ios" }
    /^doctor / { print "doctor" }
  ' "$LOG" | tr '\n' ' '
}

@test "toolchain, Maestro, Android, iOS, then the doctor, in that order" {
  all --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(milestones)" = "toolchain maestro android ios doctor " ] || fail "order: $(milestones)"
  # The doctor runs in the app, under mise's environment.
  grep -qx "mise exec -- node $WORK/doctor.mjs" "$LOG" || fail "not under mise exec: $(calls mise)"
  grep -qx "doctor $WORK/doctor.mjs in $APP" "$LOG" || fail "doctor: $(grep '^doctor' "$LOG")"
}

@test "the package's layout finishes with bin/doctor.mjs, and installs Maestro into ~/.maestro" {
  tooling_copy package
  doctor_stub "$TOOLING/bin/doctor.mjs"
  rm -rf "$HOME/.maestro"
  local zip
  zip="$(make_zip maestro 'maestro/bin/maestro=#!/bin/bash
echo 2.10.0' 'maestro/lib/maestro.jar=jar')"
  set_pin MAESTRO_SHA256 "$(sha_of 256 "$zip")"
  run bash "$COPY_SETUP/all.sh" --yes </dev/null
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "mise exec -- node $TOOLING/setup/../bin/doctor.mjs" "$LOG" || fail "doctor: $(calls mise)"
  grep -qx "doctor $TOOLING/bin/doctor.mjs in $APP" "$LOG" || fail "doctor: $(grep '^doctor' "$LOG")"
  contains "$(calls curl)" "releases/download/cli-2.10.0/maestro.zip" || fail "curl: $(calls curl)"
  [ -x "$HOME/.maestro/bin/maestro" ] || fail "maestro not in ~/.maestro/bin"
  [ -f "$HOME/.maestro/lib/maestro.jar" ] || fail "maestro's lib not in ~/.maestro/lib"
  [ ! -e "$HOME/.zshrc" ] && [ ! -e "$HOME/.bash_profile" ] || fail "a shell profile was written"
}

@test "this repository's layout finishes with packages/app-tooling/bin/doctor.mjs" {
  tooling_copy repository
  doctor_stub "$TOOLING/packages/app-tooling/bin/doctor.mjs"
  run bash "$COPY_SETUP/all.sh" --yes </dev/null
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "mise exec -- node $TOOLING/scripts/setup/../../packages/app-tooling/bin/doctor.mjs" "$LOG" \
    || fail "doctor: $(calls mise)"
  grep -qx "doctor $TOOLING/packages/app-tooling/bin/doctor.mjs in $APP" "$LOG" || fail "doctor: $(grep '^doctor' "$LOG")"
}

@test "the package's doctor is looked for first" {
  tooling_copy repository
  doctor_stub "$TOOLING/scripts/bin/doctor.mjs"
  doctor_stub "$TOOLING/packages/app-tooling/bin/doctor.mjs"
  run bash "$COPY_SETUP/all.sh" --yes </dev/null
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(grep '^doctor' "$LOG")" = "doctor $TOOLING/scripts/bin/doctor.mjs in $APP" ] \
    || fail "doctor: $(grep '^doctor' "$LOG")"
}

@test "with no doctor anywhere it stops before installing anything" {
  tooling_copy repository
  run bash "$COPY_SETUP/all.sh" --yes </dev/null
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "no doctor.mjs beside $COPY_SETUP (looked in ../bin and ../../packages/app-tooling/bin)" || fail "output: $output"
  [ ! -s "$LOG" ] || fail "did something: $(cat "$LOG")"
}

@test "a failing step stops the run before the steps after it" {
  FAKE_INSTALL_FAILURES=99 all --yes
  [ "$status" -ne 0 ] || fail "succeeded: $output"
  [ -z "$(calls xcodebuild)" ] || fail "iOS ran: $(calls xcodebuild)"
  [ -z "$(grep '^doctor' "$LOG" || true)" ] || fail "the doctor ran"
}

@test "passes its flags on, so --yes reaches the Android licences" {
  all
  [ "$status" -ne 0 ] || fail "succeeded without a yes: $output"
  contains "$output" "not confirmed: Install 9 Android SDK packages" || fail "output: $output"
}

@test "a doctor that finds a problem fails the run" {
  FAKE_DOCTOR_STATUS=3 all --yes
  [ "$status" -eq 3 ] || fail "exited $status: $output"
  contains "$(grep '^doctor' "$LOG")" "doctor $WORK/doctor.mjs" || fail "the doctor did not run"
}

@test "on Linux, the mise the toolchain step installs into ~/.local/bin is used by the steps after it" {
  mv "$FAKEBIN/mise" "$FAKEBIN/mise.real"
  printf 'mkdir -p "$HOME/.local/bin" && cp "$FAKEBIN/mise.real" "$HOME/.local/bin/mise"\n' >"$SETUP_FIXTURES/mise.run"
  plant_cmdline_tools "$HOME/Android/Sdk"
  FAKE_OS=Linux all --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(milestones)" = "toolchain maestro android doctor " ] || fail "order: $(milestones)"
  contains "$output" "not macOS: iOS setup skipped" || fail "output: $output"
}
