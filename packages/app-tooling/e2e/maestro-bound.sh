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
  #
  # The watchdog writes nothing, so it holds none of the caller's output: a
  # killed subshell does not take its running `sleep` with it, and that orphan
  # kept a pipe on this function's output open - every caller reading it waited
  # out the nap, a second on each normal run and thirty after a timeout. Each
  # nap is also waited on rather than run in the foreground, so the TERM below
  # interrupts it, and the trap ends every nap the watchdog has started: by
  # job, not by a saved pid, because the TERM can land between `sleep &` and
  # the assignment of its pid, which left the thirty-second nap running.
  local marker; marker="$(mktemp)"
  "$@" &
  local cmd_pid=$!
  (
    trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1 & nap=$!
      wait "$nap"
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    printf 1 > "$marker"
    kill -TERM "$cmd_pid" 2>/dev/null
    sleep 30 & nap=$!
    wait "$nap"
    kill -KILL "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
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
