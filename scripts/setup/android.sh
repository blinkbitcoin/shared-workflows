#!/usr/bin/env bash
# The Android SDK, every package the build needs, and an emulator, from
# nothing. Idempotent: an installed package or an existing emulator is left
# alone. Needs toolchain.sh first (java for sdkmanager, and node_modules for
# React Native's SDK pins). Run from the app's root.
#
#   bash node_modules/@blinkbitcoin/app-tooling/setup/android.sh [--yes] [--boot]
#
#   --yes   accept the Android SDK licences without asking (CI)
#   --boot  also start the emulator and wait until it has booted
set -euo pipefail
# shellcheck source=scripts/setup/lib.sh
. "$(dirname "$0")/lib.sh"
parse_common_args "$@"
# Taken before mise's environment is loaded: that brings in the ANDROID_HOME
# recorded in .env.local, which would otherwise silently override an explicit
# one (a CI runner's preinstalled SDK, or a fresh directory to install into).
explicit_sdk="${ANDROID_HOME:-}"
use_mise_env

case "$(os)" in
  darwin) default_sdk="$HOME/Library/Android/sdk" ;;
  linux) default_sdk="$HOME/Android/Sdk" ;;
  *) die "unsupported OS $(os): Android setup runs on macOS or Linux" ;;
esac
# An explicit ANDROID_HOME, else the one recorded in .env.local, else the default.
SDK="${explicit_sdk:-${ANDROID_HOME:-$default_sdk}}"
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
# `android sdk` is the command-line tools' replacement for the deprecated
# sdkmanager (tools 23+), and the only one of the two that takes --no-metrics:
# usage metrics are otherwise on by default.
ANDROID_CLI="$SDK/cmdline-tools/latest/bin/android"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"

# React Native's own pins, read rather than copied (see scripts/lib/versions.sh).
CATALOG="$SETUP_ROOT/node_modules/react-native/gradle/libs.versions.toml"
[ -f "$CATALOG" ] || die "$CATALOG is missing. Run: bash $SETUP_SCRIPTS/toolchain.sh (or pnpm install)"
pin() { sed -n "s/^$1 *= *\"\(.*\)\"/\1/p" "$CATALOG" | head -1; }
COMPILE_SDK="$(pin compileSdk)"
BUILD_TOOLS="$(pin buildTools)"
NDK="$(pin ndkVersion)"
[ -n "$COMPILE_SDK" ] && [ -n "$BUILD_TOOLS" ] && [ -n "$NDK" ] ||
  die "could not read compileSdk/buildTools/ndkVersion from $CATALOG"

case "$(uname -m)" in
  arm64 | aarch64) ABI=arm64-v8a ;;
  *) ABI=x86_64 ;;
esac
# Package names are SDK paths ("build-tools/36.0.0"); avdmanager still wants
# the old semicolon form for the image, so both spellings are kept.
SYSTEM_IMAGE="system-images/android-${SETUP_ANDROID_API_LEVEL}/google_apis/${ABI}"
SYSTEM_IMAGE_ID="${SYSTEM_IMAGE//\//;}"

step "Android SDK in $SDK"
mkdir -p "$SDK"

# The SDK's own copy of the command-line tools, never Homebrew's
# `android-commandlinetools`: that one resolves the SDK root from its own
# install location, so avdmanager fails with "Package path is not valid"
# against an SDK anywhere else.
if [ -x "$ANDROID_CLI" ]; then
  ok "command-line tools ($ANDROID_CLI)"
else
  case "$(os)/$(uname -m)" in
    darwin/arm64) platform=mac_arm64 sha="$ANDROID_CMDLINE_TOOLS_SHA1_DARWIN_ARM64" ;;
    darwin/*) platform=mac_x86_64 sha="$ANDROID_CMDLINE_TOOLS_SHA1_DARWIN_X86_64" ;;
    *) platform=linux sha="$ANDROID_CMDLINE_TOOLS_SHA1_LINUX" ;;
  esac
  zip="commandlinetools-${platform}-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip"
  work="$(mktemp -d)"
  info "downloading $zip"
  retry 3 curl -fsSL -o "$work/tools.zip" "https://dl.google.com/android/repository/$zip"
  sha_ok 1 "$sha" "$work/tools.zip" || die "refusing an unverified $zip"
  unzip -q "$work/tools.zip" -d "$work"
  mkdir -p "$SDK/cmdline-tools"
  rm -rf "$SDK/cmdline-tools/latest"
  mv "$work/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -rf "$work"
  ok "command-line tools ${ANDROID_CMDLINE_TOOLS_BUILD}"
fi

# One package per call, each retried: a reset connection then costs one
# package, not the whole list, and the log names the one that failed.
installed() { [ -f "$SDK/$1/source.properties" ]; }
read -ra agp_defaults <<<"$ANDROID_AGP_DEFAULT_PACKAGES"
packages=(
  platform-tools
  emulator
  "platforms/android-${COMPILE_SDK}"
  "build-tools/${BUILD_TOOLS}"
  "ndk/${NDK}"
  "${agp_defaults[@]}"
  "$SYSTEM_IMAGE"
)
missing=()
for package in "${packages[@]}"; do
  installed "$package" || missing+=("$package")
done

# The command-line tools accept a package's licence silently as they install
# it (and write it to $SDK/licenses, where Gradle looks). So the install *is*
# the acceptance, and the question comes before the first one, not after.
if [ "${#missing[@]}" -gt 0 ] && [ ! -f "$SDK/licenses/android-sdk-license" ]; then
  consent "Install ${#missing[@]} Android SDK packages, accepting their licences (https://developer.android.com/studio/terms)"
fi

for package in "${packages[@]}"; do
  if installed "$package"; then
    ok "$package"
  else
    info "installing $package"
    retry 3 "$ANDROID_CLI" --no-metrics sdk install --sdk="$SDK" "$package" </dev/null >/dev/null
    installed "$package" || die "$package did not install (no source.properties)"
    ok "$package"
  fi
done

step "emulator $SETUP_ANDROID_AVD_NAME"
# Output is captured before it is searched, and avdmanager's answer comes from a
# here-string, never a pipe. Under pipefail a pipe's writer that outlives its
# reader dies of SIGPIPE: `grep -q` stops reading at the first match, so a long
# AVD list made an existing AVD look missing, and an avdmanager that exits
# without reading its prompt answer killed the whole script with status 141.
avds="$("$SDK/emulator/emulator" -list-avds 2>/dev/null || true)"
if grep -qx "$SETUP_ANDROID_AVD_NAME" <<<"$avds"; then
  ok "$SETUP_ANDROID_AVD_NAME exists"
else
  "$AVDMANAGER" create avd --name "$SETUP_ANDROID_AVD_NAME" \
    --package "$SYSTEM_IMAGE_ID" -d "$SETUP_ANDROID_AVD_DEVICE" >/dev/null <<<no
  ok "created $SETUP_ANDROID_AVD_NAME ($SETUP_ANDROID_AVD_DEVICE, API $SETUP_ANDROID_API_LEVEL, $ABI)"
fi

step "environment"
# .mise.toml loads .env.local and derives PATH from ANDROID_HOME, so adb,
# emulator and sdkmanager are on PATH in every mise-activated shell.
set_env_local ANDROID_HOME "$SDK"
ok "ANDROID_HOME=$SDK recorded in .env.local"

if [ "$SETUP_BOOT" = 1 ]; then
  step "boot $SETUP_ANDROID_AVD_NAME"
  ADB="$SDK/platform-tools/adb"
  devices="$("$ADB" devices)"
  if grep -q '^emulator-.*device$' <<<"$devices"; then
    ok "an emulator is already running"
  else
    flags=(-avd "$SETUP_ANDROID_AVD_NAME" -no-snapshot-save -no-boot-anim -netdelay none -netspeed full)
    # A CI runner has no display.
    [ -n "${CI:-}" ] && flags+=(-no-window -no-audio -gpu swiftshader_indirect)
    log="${TMPDIR:-/tmp}/emulator-$SETUP_ANDROID_AVD_NAME.log"
    nohup "$SDK/emulator/emulator" "${flags[@]}" >"$log" 2>&1 &
    info "started (log: $log), waiting for boot"
    "$ADB" wait-for-device
    for _ in $(seq 1 "${SETUP_BOOT_TIMEOUT:-180}"); do
      [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
      sleep 1
    done
    [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] ||
      die "emulator did not finish booting; see $log"
    ok "booted"
  fi
  # Maestro's own advice: animations make taps land on moving targets.
  for setting in window_animation_scale transition_animation_scale animator_duration_scale; do
    "$ADB" shell settings put global "$setting" 0
  done
  ok "animations off"
fi

cat <<EOF

Android is ready. A mise-activated shell has adb and the emulator on PATH; elsewhere:
  export ANDROID_HOME=$SDK PATH="$SDK/platform-tools:$SDK/emulator:\$PATH"
EOF
