#!/usr/bin/env bash
# Sourced by ios-maestro.sh and android-maestro.sh. A starved emulator or
# simulator can leave Maestro waiting on its driver with no flow output. Bound
# the suite here, inside the script, so what follows (the Android logcat
# post-mortem, the suite retry decision, forensics collection) still runs: the
# step's timeout-minutes is only the backstop and kills the script outright.
#
#   bounded_maestro <seconds> <cmd> [args...]  -> exit status; 124 on timeout
#
# coreutils `timeout` on ubuntu runners, `gtimeout` (Homebrew coreutils) on
# macOS runners; on a stock Mac neither exists, so a pure-bash watchdog takes
# over instead of running the suite unbounded.
# shellcheck shell=bash

bounded_maestro() {
  local secs="${1:?usage: bounded_maestro SECONDS CMD [ARGS...]}"
  shift
  [ "$#" -gt 0 ] || { printf '::error::bounded_maestro needs a command\n'; return 2; }

  local t status=0
  if t=$(command -v timeout || command -v gtimeout); then
    "$t" -k 30s "${secs}s" "$@" || status=$?
    [ "$status" -eq 124 ] && printf '::error::Maestro suite exceeded %ss without completing\n' "$secs"
    return "$status"
  fi

  # Fallback watchdog: run the command in the background and poll it once a
  # second. The marker file (not the exit status) is what distinguishes "we
  # killed it" from "it exited with 143 on its own".
  local marker; marker="$(mktemp)"
  "$@" &
  local cmd_pid=$!
  (
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    printf 1 > "$marker"
    kill -TERM "$cmd_pid" 2>/dev/null
    sleep 30
    kill -KILL "$cmd_pid" 2>/dev/null
  ) &
  local watchdog_pid=$!
  wait "$cmd_pid" || status=$?
  kill -TERM "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null || true
  if [ -s "$marker" ]; then
    status=124
    printf '::error::Maestro suite exceeded %ss without completing\n' "$secs"
  fi
  rm -f "$marker"
  return "$status"
}
