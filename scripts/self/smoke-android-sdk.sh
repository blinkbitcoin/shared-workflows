#!/usr/bin/env bash
# Provision the Android SDK the local smoke's Android leg builds against.
#
# GitHub's ubuntu-latest ships an Android SDK and build-android.yml relies on
# it; act's runner image has none, so Gradle stopped at configuration with "SDK
# location not found". smoke-local.sh keeps an SDK in a Docker volume, mounts it
# into every job at $ANDROID_HOME, and runs this once - after the developer has
# agreed to the licences - inside an amd64 JDK container (the command-line
# tools' `android` binary is x86-64 only, and the JDK image brings curl and a
# zip reader), with the volume at $ANDROID_HOME and this repository's scripts/
# mounted read-only.
#
# It installs the pinned command-line tools, then the packages the Android
# Gradle Plugin falls back to, which Gradle would otherwise fetch mid-build.
# `android sdk install` accepts each package's licence as it installs it and
# records that where Gradle looks ($ANDROID_HOME/licenses) - `sdkmanager
# --licenses` is deprecated and, in this build, records nothing - so the
# install is the acceptance, which smoke-local.sh asks for first. Everything
# else the app asks for (its platform, its build-tools) Gradle fetches into the
# same volume on the first build, under those licences, and it stays there.
#
# Usage: ANDROID_HOME=/opt/android-sdk smoke-android-sdk.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/versions.sh"
require_cmd curl sha1sum jar

sdk="${ANDROID_HOME:-}"
[ -n "$sdk" ] || die "ANDROID_HOME is not set - smoke-local.sh sets it to where the SDK volume is mounted"
android="$sdk/cmdline-tools/latest/bin/android"

if [ -x "$android" ]; then
  log "android sdk: command-line tools already in $sdk"
else
  zip="commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip"
  work="$(mktemp -d)"
  log "android sdk: downloading $zip"
  curl -fsSL --retry 3 -o "$work/tools.zip" "https://dl.google.com/android/repository/$zip" ||
    die "could not download $zip"
  printf '%s  %s\n' "$ANDROID_CMDLINE_TOOLS_SHA1_LINUX" "$work/tools.zip" | sha1sum -c - >/dev/null 2>&1 ||
    die "refusing an unverified $zip: its SHA-1 is not $ANDROID_CMDLINE_TOOLS_SHA1_LINUX"
  # The JDK image has no unzip; the JDK's jar reads a zip, but keeps no modes.
  (cd "$work" && jar xf tools.zip) || die "could not unpack $zip"
  chmod +x "$work"/cmdline-tools/bin/*
  mkdir -p "$sdk/cmdline-tools"
  rm -rf "$sdk/cmdline-tools/latest"
  mv "$work/cmdline-tools" "$sdk/cmdline-tools/latest"
  rm -rf "$work"
fi

# One package per call, each tried three times: a reset connection then costs
# one package, not the list, and the log names the one that failed.
read -ra packages <<<"platform-tools $ANDROID_AGP_DEFAULT_PACKAGES"
for package in "${packages[@]}"; do
  if [ -f "$sdk/$package/source.properties" ]; then
    log "android sdk: $package already installed"
    continue
  fi
  log "android sdk: installing $package"
  attempt=1
  until "$android" --no-metrics sdk install --sdk="$sdk" "$package" </dev/null >/dev/null; do
    [ "$attempt" -lt 3 ] || die "could not install $package after 3 attempts"
    attempt=$((attempt + 1))
  done
  [ -f "$sdk/$package/source.properties" ] || die "$package did not install (no source.properties)"
done
[ -f "$sdk/licenses/android-sdk-license" ] || die "no licence was recorded: $sdk/licenses/android-sdk-license is missing, so Gradle could fetch nothing"
log "android sdk: ready in $sdk"
