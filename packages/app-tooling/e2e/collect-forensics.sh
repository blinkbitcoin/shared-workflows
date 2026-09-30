#!/usr/bin/env bash
# Post-mortem artifacts for a failed (or passing) E2E run, left in
# $WORKFLOWS_OUT/forensics/ for upload-artifact. Never fails the job: forensics that
# can turn a red run green-by-accident, or red-by-accident, are worse than no
# forensics - every step is `|| true` and the script always exits 0.
# Usage: collect-forensics.sh <ios|android>
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

platform="$(workflows_platform "${1:-}" 2>/dev/null || printf '%s\n' "${WORKFLOWS_PLATFORM:-}")"
dest="$WORKFLOWS_OUT/forensics"
mkdir -p "$dest" || exit 0

cp "$WORKFLOWS_OUT/metro.log" "$dest/" 2>/dev/null || true
cp "$WORKFLOWS_OUT"/*.mp4 "$dest/" 2>/dev/null || true
cp "$WORKFLOWS_OUT/ios-unified.log" "$dest/" 2>/dev/null || true
# Maestro writes junit.xml and the per-command debug output (screenshots, device
# logs, command hierarchy) to $WORKFLOWS_OUT/maestro, a *sibling* of forensics/. The
# forensics action only uploads forensics/, so without this copy the artifact
# never carries the single most useful thing for diagnosing a failed flow.
if [ -d "$WORKFLOWS_OUT/maestro" ]; then
  cp -R "$WORKFLOWS_OUT/maestro" "$dest/" 2>/dev/null || true
fi

if [ "$platform" = ios ]; then
  # Only reports from this run: the folder accumulates across a developer's
  # whole session and an unrelated crash log is a red herring. The reference is
  # e2e-env.sh's run-start stamp, never metro.log - metro.log is appended all
  # run long, so it would only ever select reports newer than the last bundle
  # request. The hour window is the fallback when no stamp exists.
  if [ -d "$HOME/Library/Logs/DiagnosticReports" ]; then
    if [ -f "$WORKFLOWS_RUN_START" ] && [ -z "$WORKFLOWS_RUN_START_FRESH" ]; then
      find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
        -newer "$WORKFLOWS_RUN_START" -exec cp {} "$dest/" \; 2>/dev/null || true
    else
      find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
        -mmin -60 -exec cp {} "$dest/" \; 2>/dev/null || true
    fi
  fi
  crashes=$(find "$dest" -maxdepth 1 \( -name '*.ips' -o -name '*.crash' \) 2>/dev/null | wc -l | tr -d ' ')
  log "collected forensics in $dest (iOS crash reports: ${crashes:-0})"
elif [ "$platform" = android ]; then
  adb logcat -d > "$dest/logcat.txt" 2>/dev/null || true
  adb logcat -d -b crash > "$dest/logcat-crash.txt" 2>/dev/null || true
  group "logcat crash buffer"
  tail -200 "$dest/logcat-crash.txt" 2>/dev/null || true
  endgroup
  group "logcat: app lifecycle (last 200 matching lines)"
  grep -aiE 'ReactNativeJS|AndroidRuntime|FATAL|Fatal signal|lowmemorykiller|has died|app died' \
    "$dest/logcat.txt" 2>/dev/null | tail -200 || true
  endgroup
  log "collected forensics in $dest"
else
  log "collect-forensics: unknown platform '${platform}' - kept the platform-neutral files only"
fi
exit 0
