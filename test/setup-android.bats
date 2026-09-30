#!/usr/bin/env bats
# scripts/setup/android.sh - the Android SDK, every package the app's build
# needs and an emulator, from nothing, into the app the working directory
# holds. Run against a fake Android CLI, avdmanager, emulator, adb, curl and
# mise, in a throwaway app and HOME (test/setup_helper.bash). Most cases run a
# copy of the scripts whose command-line tools checksums match the fixture
# archive; one runs the real script with the tools already in place.
#
# Covers every way out: an unknown flag; no mise; an OS other than macOS or
# Linux; each SDK location (explicit ANDROID_HOME, the one in .env.local, the
# default on macOS and on Linux); no catalogue, and one without the SDK pins;
# the command-line tools present, downloaded for each platform, and a tampered
# download; the licence question (refused, --yes, SETUP_YES, already accepted,
# and a yes or no on a terminal); a package installed, retried, given up on,
# and one that reports success but leaves nothing; an AVD that exists (at the
# top of a long list) or is created; and --boot with an emulator running (at
# the top of a long list), started with and without CI's flags, and one that
# never finishes booting.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper
load setup_helper

setup() {
  setup_sandbox
  REAL="$REPO_ROOT/scripts/setup/android.sh"
  tooling_copy repository
  SCRIPT="$COPY_SETUP/android.sh"
  local zip sum build platform
  zip="$(cmdline_tools_zip)"
  sum="$(sha_of 1 "$zip")"
  build="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; echo "$ANDROID_CMDLINE_TOOLS_BUILD"')"
  for platform in mac_arm64 mac_x86_64 linux; do
    cp "$zip" "$SETUP_FIXTURES/commandlinetools-$platform-${build}_latest.zip"
  done
  for platform in DARWIN_ARM64 DARWIN_X86_64 LINUX; do
    set_pin "ANDROID_CMDLINE_TOOLS_SHA1_$platform" "$sum"
  done
}

# android ARGUMENTS...: runs the copy with no terminal to answer consent.
android() { run bash "$SCRIPT" "$@" </dev/null; }

# A list whose first line is $1 and which is longer than a pipe buffer holds:
# a pipe into `grep -q` loses that race, since grep exits at the first match,
# the writer dies of SIGPIPE and pipefail reports the search as failed.
long_list_after() {
  printf '%s\n' "$1"
  local i
  for i in $(seq 1 20000); do printf 'padding line %s\n' "$i"; done
}

BLANK_INSTALLS="platform-tools
emulator
platforms/android-36
build-tools/36.0.0
ndk/27.1.12297006
ndk/27.0.12077973
build-tools/35.0.0
cmake/3.22.1
system-images/android-36/google_apis/arm64-v8a"

@test "a blank machine gets the SDK, every build package and the emulator" {
  android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  # The SDK's own command-line tools, unpacked from the checksummed archive.
  [ -x "$SDK/cmdline-tools/latest/bin/android" ] || fail "command-line tools not unpacked"
  contains "$(calls curl)" "https://dl.google.com/android/repository/commandlinetools-mac_arm64-" || fail "curl: $(calls curl)"
  # React Native's pins from its catalogue, AGP's fallbacks, and the image.
  [ "$(installs)" = "$BLANK_INSTALLS" ] || fail "installs: $(installs)"
  # Every install opts out of the CLI's default-on usage metrics.
  [ -z "$(calls android | grep -v '^android --no-metrics sdk install --sdk=')" ] || fail "calls: $(calls android)"
  # avdmanager wants the semicolon form of the image path.
  contains "$(calls avdmanager)" "create avd --name Pixel_10_API_36 --package system-images;android-36;google_apis;arm64-v8a -d pixel_10" \
    || fail "avdmanager: $(calls avdmanager)"
  [ "$(cat "$APP/.env.local")" = "ANDROID_HOME=$SDK" ] || fail ".env.local: $(cat "$APP/.env.local")"
  contains "$output" "Android is ready." || fail "output: $output"
}

@test "the real script uses the real pins, with the command-line tools already there" {
  plant_cmdline_tools "$SDK"
  run bash "$REAL" --yes </dev/null
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$(calls curl)" ] || fail "downloaded the tools again: $(calls curl)"
  contains "$output" "ok    command-line tools ($SDK/cmdline-tools/latest/bin/android)" || fail "output: $output"
  [ "$(installs)" = "$BLANK_INSTALLS" ] || fail "installs: $(installs)"
  contains "$output" "created Pixel_10_API_36 (pixel_10, API 36, arm64-v8a)" || fail "output: $output"
}

@test "packages follow the React Native catalogue, not a copy of it" {
  catalog 37 37.0.0 28.0.1
  android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local all
  all="$(installs)"
  contains "$all" "platforms/android-37" || fail "installs: $all"
  contains "$all" "build-tools/37.0.0" || fail "installs: $all"
  contains "$all" "ndk/28.0.1" || fail "installs: $all"
}

@test "installing accepts licences, so nothing installs without a yes" {
  android
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "not confirmed: Install 9 Android SDK packages, accepting their licences" || fail "output: $output"
  contains "$output" "SETUP_YES=1" || fail "output: $output"
  [ -z "$(calls android)" ] || fail "installed anyway: $(calls android)"
}

@test "SETUP_YES=1 in the environment is the same yes as --yes" {
  SETUP_YES=1 android
  [ "$status" -eq 0 ] || fail "exited $status: $output"
}

@test "an SDK whose licences were accepted before is not asked again" {
  android --yes
  [ "$status" -eq 0 ] || fail "first run: $output"
  rm -rf "$SDK/cmake"
  : >"$LOG"
  android
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(installs)" = "cmake/3.22.1" ] || fail "installs: $(installs)"
}

@test "a second run changes nothing" {
  printf 'OTHER=kept\nANDROID_HOME=/old/sdk\n' >"$APP/.env.local"
  # Explicit on the first run; the second relies on what that one recorded.
  ANDROID_HOME="$SDK" android --yes
  [ "$status" -eq 0 ] || fail "first run: $output"
  : >"$LOG"
  android
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$(calls curl)$(calls android)$(calls avdmanager)" ] || fail "changed something: $(cat "$LOG")"
  contains "$output" "Pixel_10_API_36 exists" || fail "output: $output"
  # Other per-machine values survive; ANDROID_HOME is replaced, not repeated.
  [ "$(cat "$APP/.env.local")" = "OTHER=kept
ANDROID_HOME=$SDK" ] || fail ".env.local: $(cat "$APP/.env.local")"
}

@test "a dropped connection mid-install is retried, not fatal" {
  FAKE_INSTALL_FAILURES=2 android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "attempt 1 of 3 failed" || fail "output: $output"
  [ "$(installs | grep -cx platform-tools)" = 3 ] || fail "attempts: $(installs)"
}

@test "a package that keeps failing stops the run and names itself" {
  FAKE_INSTALL_FAILURES=99 android --yes
  [ "$status" -ne 0 ] || fail "succeeded: $output"
  printf '%s\n' "$output" | grep -qE 'gave up after 3 attempts: .*platform-tools' || fail "output: $output"
}

@test "a tampered command-line tools download is refused" {
  printf 'not the archive\n' >"$SETUP_FIXTURES/commandlinetools-mac_arm64-16111833_latest.zip"
  android --yes
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "checksum mismatch" || fail "output: $output"
  contains "$output" "refusing an unverified commandlinetools-mac_arm64-16111833_latest.zip" || fail "output: $output"
  [ ! -e "$SDK/cmdline-tools/latest" ] || fail "the tools were unpacked anyway"
}

@test "ANDROID_HOME, when set, is where the SDK goes" {
  local custom="$WORK/custom-sdk"
  ANDROID_HOME="$custom" android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -f "$custom/platform-tools/source.properties" ] || fail "not installed into $custom"
  [ "$(cat "$APP/.env.local")" = "ANDROID_HOME=$custom" ] || fail ".env.local: $(cat "$APP/.env.local")"
}

@test "an explicit ANDROID_HOME wins over the one recorded in .env.local" {
  printf 'ANDROID_HOME=/recorded/elsewhere\n' >"$APP/.env.local"
  local custom="$WORK/explicit-sdk"
  ANDROID_HOME="$custom" android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -f "$custom/platform-tools/source.properties" ] || fail "not installed into $custom"
  [ "$(cat "$APP/.env.local")" = "ANDROID_HOME=$custom" ] || fail ".env.local: $(cat "$APP/.env.local")"
}

@test "without an explicit one, the SDK recorded in .env.local is reused" {
  local recorded="$WORK/recorded-sdk"
  printf 'ANDROID_HOME=%s\n' "$recorded" >"$APP/.env.local"
  android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -f "$recorded/platform-tools/source.properties" ] || fail "not installed into $recorded"
}

@test "Linux on x86_64 gets its own archive, image and SDK directory" {
  FAKE_OS=Linux FAKE_ARCH=x86_64 android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(calls curl)" "commandlinetools-linux-" || fail "curl: $(calls curl)"
  contains "$(installs)" "system-images/android-36/google_apis/x86_64" || fail "installs: $(installs)"
  [ -d "$HOME/Android/Sdk/platform-tools" ] || fail "not in ~/Android/Sdk"
}

@test "Linux on aarch64 gets the Linux archive and the arm64 image" {
  FAKE_OS=Linux FAKE_ARCH=aarch64 android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(calls curl)" "commandlinetools-linux-" || fail "curl: $(calls curl)"
  contains "$(installs)" "system-images/android-36/google_apis/arm64-v8a" || fail "installs: $(installs)"
}

@test "an Intel Mac gets the x86_64 archive and image" {
  FAKE_ARCH=x86_64 android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(calls curl)" "commandlinetools-mac_x86_64-" || fail "curl: $(calls curl)"
  contains "$(installs)" "system-images/android-36/google_apis/x86_64" || fail "installs: $(installs)"
}

@test "without node_modules it names the script that installs them" {
  rm -rf "$APP/node_modules"
  android --yes
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "libs.versions.toml is missing. Run: bash node_modules/@blinkbitcoin/app-tooling/setup/toolchain.sh (or pnpm install)" \
    || fail "output: $output"
}

@test "a catalogue without the SDK pins is an error, not an empty package name" {
  catalog 36 36.0.0 ""
  android --yes
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "could not read compileSdk/buildTools/ndkVersion" || fail "output: $output"
  [ -z "$(calls android)" ] || fail "installed anyway: $(calls android)"
}

@test "an OS other than macOS or Linux is refused" {
  FAKE_OS=FreeBSD android --yes
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "unsupported OS freebsd" || fail "output: $output"
}

@test "without mise it names the script that installs it" {
  rm "$FAKEBIN/mise"
  android --yes
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "mise is not installed. Run: bash node_modules/@blinkbitcoin/app-tooling/setup/toolchain.sh" || fail "output: $output"
}

@test "an unknown flag is refused instead of ignored" {
  android --yess
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "unknown argument: --yess" || fail "output: $output"
}

@test "an install that reports success but leaves nothing behind is caught" {
  android --yes
  [ "$status" -eq 0 ] || fail "first run: $output"
  rm -rf "$SDK/cmake"
  printf 'true\n' >"$FAKEBIN/android.impl"
  android
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "cmake/3.22.1 did not install (no source.properties)" || fail "output: $output"
}

@test "an existing AVD is found even at the top of a long AVD list" {
  long_list_after Pixel_10_API_36 >"$WORK/avds"
  android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "Pixel_10_API_36 exists" || fail "output: $output"
  [ -z "$(calls avdmanager)" ] || fail "created anyway: $(calls avdmanager)"
}

@test "avdmanager is told not to create a custom hardware profile" {
  android --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$WORK/avdmanager-answer")" = no ] || fail "answer: $(cat "$WORK/avdmanager-answer")"
}

@test "--boot sees a running emulator at the top of a long device list" {
  android --yes
  [ "$status" -eq 0 ] || fail "first run: $output"
  { printf 'List of devices attached\n'; long_list_after "emulator-5554	device"; } >"$WORK/adb-devices"
  android --boot
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "an emulator is already running" || fail "output: $output"
}

@test "--boot under CI starts a windowless emulator, waits for boot and turns animations off" {
  android --yes
  [ "$status" -eq 0 ] || fail "first run: $output"
  : >"$LOG"
  CI=true android --boot
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local started
  started="$(calls_once_logged emulator ' -avd ')" || fail "the emulator was never started"
  printf '%s\n' "$started" | grep -qE -- '-avd Pixel_10_API_36 .*-no-window -no-audio -gpu swiftshader_indirect' || fail "flags: $started"
  [ "$(calls adb | grep -cE 'animation_scale|animator_duration_scale')" = 3 ] || fail "animations: $(calls adb)"
  contains "$output" "booted" || fail "output: $output"
  contains "$output" "animations off" || fail "output: $output"

  : >"$LOG"
  FAKE_ADB_DEVICES="emulator-5554	device" android --boot
  [ "$status" -eq 0 ] || fail "second run: $output"
  contains "$output" "an emulator is already running" || fail "output: $output"
  [ -z "$(calls emulator | grep -- ' -avd ' || true)" ] || fail "started a second one: $(calls emulator)"
}

@test "--boot on a laptop starts the emulator with a window" {
  android --yes
  [ "$status" -eq 0 ] || fail "first run: $output"
  : >"$LOG"
  android --boot
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local started
  started="$(calls_once_logged emulator ' -avd ')" || fail "the emulator was never started"
  not_contains "$started" "-no-window" || fail "flags: $started"
}

@test "--boot gives up on an emulator that never finishes booting" {
  android --yes
  [ "$status" -eq 0 ] || fail "first run: $output"
  cat >"$FAKEBIN/adb.impl" <<'EOF'
case "$1 ${2:-}" in "devices ") echo 'List of devices attached' ;; "shell getprop") echo 0 ;; esac
true
EOF
  SETUP_BOOT_TIMEOUT=2 android --boot
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  printf '%s\n' "$output" | grep -qE 'emulator did not finish booting; see .*emulator-Pixel_10_API_36\.log' || fail "output: $output"
}

@test "in a terminal, the licence question is asked and a yes installs" {
  in_terminal y "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  printf '%s\n' "$output" | grep -qE '\?\? {4}Install 9 Android SDK packages, accepting their licences.*\[y/N\]' || fail "output: $output"
  [ "$(installs | wc -l | tr -d ' ')" = 9 ] || fail "installs: $(installs)"
}

@test "in a terminal, anything but yes is a no" {
  in_terminal n "$SCRIPT"
  [ "$status" -ne 0 ] || fail "succeeded: $output"
  contains "$output" "not confirmed" || fail "output: $output"
  [ -z "$(calls android)" ] || fail "installed anyway: $(calls android)"
}
