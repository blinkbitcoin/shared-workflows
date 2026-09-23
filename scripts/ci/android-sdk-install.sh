#!/usr/bin/env bash
# Installs Android SDK packages, retrying a download that lands corrupt.
#
# ReactiveCircus/android-emulator-runner installs the packages it needs itself
# and has no retry, so one bad download takes the whole Android E2E job down
# before Maestro ever runs ("An error occurred while preparing SDK package
# Android Emulator: Error on ZipFile unknown archive", then adb failing to
# reach an emulator that never started). Pre-installing here makes the action's
# own sdkmanager call a no-op - it skips a package already at the current
# revision, the same property the system-image cache in check-e2e.yml relies on - so
# a corrupt archive costs a retry instead of the job.
#
# Usage: android-sdk-install.sh <sdk-package>...   (ANDROID_SDK_RETRIES: 2)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Exit 2, not die's 1: a call that names no package is the caller's bug, not a
# failed install, and the two must be distinguishable from a workflow step.
[ "$#" -gt 0 ] || { printf '::error::usage: %s <sdk-package>...\n' "$0" >&2; exit 2; }

retries="${ANDROID_SDK_RETRIES:-2}"
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$sdk_root" ] || die "neither ANDROID_HOME nor ANDROID_SDK_ROOT is set"

# sdkmanager is not on PATH on the GitHub runners - it ships inside the SDK
# itself, and which directory holds it depends on how the SDK was laid down
# (cmdline-tools/latest on the hosted images, a versioned sibling or the
# retired tools/bin elsewhere). Resolve it here: a missing binary is a broken
# runner image, not a bad download, so it must fail loudly instead of being
# retried - a bare `sdkmanager` dies with "command not found" in milliseconds
# and the retry loop buries the cause.
sdkmanager=""
for candidate in "$sdk_root"/cmdline-tools/latest/bin/sdkmanager \
  "$sdk_root"/cmdline-tools/*/bin/sdkmanager \
  "$sdk_root"/tools/bin/sdkmanager; do
  if [ -x "$candidate" ]; then
    sdkmanager="$candidate"
    break
  fi
done
[ -n "$sdkmanager" ] || die "no sdkmanager under $sdk_root (looked in cmdline-tools/*/bin and tools/bin)"

attempt=0
while :; do
  # --channel=0 (stable) is what the action asks for, so the revision resolved
  # here is the one it then finds installed. stdin is closed so an unaccepted
  # licence fails instead of waiting for a prompt that will never come; stdout
  # is dropped (progress bars only) and stderr kept - that is where sdkmanager
  # reports the archive it could not read.
  if "$sdkmanager" --install "$@" --channel=0 < /dev/null > /dev/null; then
    printf 'Installed: %s\n' "$*"
    exit 0
  fi

  if [ "$attempt" -ge "$retries" ]; then
    die "sdkmanager could not install '$*' in $((attempt + 1)) attempts"
  fi
  attempt=$((attempt + 1))

  # The half-written archive is cached and replayed, so every later attempt
  # fails identically until the cache is gone.
  rm -rf "$sdk_root/.downloadIntermediates" "$HOME/.android/cache"
  log "sdkmanager failed; purged the download cache, retry $attempt of $retries"
done
