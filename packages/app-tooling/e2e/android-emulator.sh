#!/usr/bin/env bash
# Android emulator plumbing for the E2E job. Runs against whatever emulator adb
# already sees (reactivecircus/android-emulator-runner boots it).
#   snapshot-bake  settings that must survive into the saved AVD snapshot
#   prepare        install the APK, reverse the host ports, arm logcat
#   record start   loop 3-minute screenrecord chunks into $WORKFLOWS_OUT/android-N.mp4
#   record stop    stop the loop and pull the last chunk
# Usage: android-emulator.sh snapshot-bake | prepare [apk] | record start|stop
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

require_cmd adb
rec_pid_file="$WORKFLOWS_OUT/android-record.pid"

# A starved CI emulator throws "X isn't responding" dialogs (even for the
# launcher) on top of the app under test, which then fails visibility
# assertions. Real crashes still land in logcat. Animations off makes Maestro's
# view-hierarchy polling deterministic.
quiet_device() {
  adb shell settings put global hide_error_dialogs 1
  adb shell settings put global anr_show_background 0
  adb shell settings put global window_animation_scale 0
  adb shell settings put global transition_animation_scale 0
  adb shell settings put global animator_duration_scale 0
}

case "${1:-}" in
  snapshot-bake)
    quiet_device
    log "device quieted (baked into the snapshot)"
    ;;
  prepare)
    root="$(consumer_root)"
    apk="${2:-$root/$WORKFLOWS_ANDROID_APK}"
    [ -f "$apk" ] || die "no APK at $apk - run android-build.sh first"
    adb install -r "$apk"
    # Metro and the consumer's mock API both live on the host; the emulator
    # reaches them through reversed ports rather than 10.0.2.2 so the app's
    # localhost URLs work unchanged.
    adb reverse "tcp:$WORKFLOWS_METRO_PORT" "tcp:$WORKFLOWS_METRO_PORT"
    if [ -n "$WORKFLOWS_MOCK_API_PORT" ]; then
      adb reverse "tcp:$WORKFLOWS_MOCK_API_PORT" "tcp:$WORKFLOWS_MOCK_API_PORT"
    fi
    # The default 256K main buffer wraps within a couple of minutes on the
    # emulator, losing the app-launch window from the post-mortem dump.
    adb logcat -G 64M
    adb logcat -c
    # A restored snapshot can predate snapshot-bake; re-assert, it is cheap.
    quiet_device
    log "emulator prepared with $apk"
    ;;
  record)
    case "${2:-}" in
      start)
        # screenrecord caps a single file at 3 minutes, so a suite needs a loop
        # of chunks pulled as they finish.
        (
          i=0
          while :; do
            adb shell screenrecord --time-limit 180 /sdcard/workflows-rec.mp4 || break
            adb pull /sdcard/workflows-rec.mp4 "$WORKFLOWS_OUT/android-$i.mp4" >/dev/null 2>&1 || true
            i=$((i + 1))
          done
        ) > "$WORKFLOWS_OUT/android-record.log" 2>&1 &
        # The redirect is not cosmetic: a background job that keeps the caller's
        # stdout open hangs anything that pipes this script's output.
        printf '%s\n' "$!" > "$rec_pid_file"
        log "recording to $WORKFLOWS_OUT/android-N.mp4 (pid $(cat "$rec_pid_file"))"
        ;;
      stop)
        [ -f "$rec_pid_file" ] || { log "no recording in progress"; exit 0; }
        kill "$(cat "$rec_pid_file")" 2>/dev/null || true
        adb shell pkill -INT screenrecord 2>/dev/null || true
        sleep 3
        adb pull /sdcard/workflows-rec.mp4 "$WORKFLOWS_OUT/android-last.mp4" >/dev/null 2>&1 || true
        rm -f "$rec_pid_file"
        log "recording stopped"
        ;;
      *) die "usage: android-emulator.sh record start|stop" ;;
    esac
    ;;
  *) die "usage: android-emulator.sh snapshot-bake | prepare [apk] | record start|stop" ;;
esac
