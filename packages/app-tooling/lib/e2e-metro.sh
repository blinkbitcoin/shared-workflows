#!/usr/bin/env bash
# The host-side services an E2E run talks to: Metro, started in the background
# by both stacks' metro-start.sh, and the port of the consumer's mock API. Part
# of the env contract scripts/lib/e2e-env.sh assembles; source that, after
# common.sh.
# shellcheck shell=bash

source "$(dirname "${BASH_SOURCE[0]}")/shared-env.sh"

WORKFLOWS_METRO_PORT="${WORKFLOWS_METRO_PORT:-8081}"
# Host-side mock API the E2E setup hook starts. Reversed into the emulator so
# the app's localhost URLs work unchanged; empty disables the reverse entirely.
# 8082 is the template's port base (8080) plus its mock-API offset, beside
# Metro's 8081 at offset 1: the template derives every port from one base so
# two checkouts can run side by side, and its mock server moved from 4000.
WORKFLOWS_MOCK_API_PORT="${WORKFLOWS_MOCK_API_PORT-8082}"
export WORKFLOWS_METRO_PORT WORKFLOWS_MOCK_API_PORT

# workflows_metro_background COMMAND [ARG...] - start Metro in the background,
# the one contract both stacks' metro-start.sh share. nohup + a pid file so the
# process survives the step that started it (each GitHub Actions step is its
# own shell) and can be killed deterministically at the end of the job; CI=1 so
# neither CLI waits on an interactive prompt.
# Log: $WORKFLOWS_OUT/metro.log  Pid: $WORKFLOWS_OUT/metro.pid
workflows_metro_background() {
  local pid
  # Job control on: the background job then leads its own process group, so
  # `kill -TERM -$(cat metro.pid)` takes the whole tree down. Killing the pid
  # alone only reaps the pnpm wrapper and leaves node holding the port.
  set -m
  CI=1 nohup "$@" > "$WORKFLOWS_OUT/metro.log" 2>&1 &
  pid=$!
  set +m
  printf '%s\n' "$pid" > "$WORKFLOWS_OUT/metro.pid"
  log "Metro starting (pid $pid, port $WORKFLOWS_METRO_PORT, log $WORKFLOWS_OUT/metro.log)"
  log "stop it with: kill -TERM -$pid"
}
