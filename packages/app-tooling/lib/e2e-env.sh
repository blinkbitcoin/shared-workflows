#!/usr/bin/env bash
# Shared env contract for scripts/native and scripts/e2e. Source it after
# common.sh; do not execute. Every variable is optional and has a default, so a
# consumer only sets what it needs to override (see scripts/e2e/README.md).
#
# This file is the one entry point. It assembles the contract from one file
# per responsibility, none of which touches the disk or $GITHUB_ENV when
# sourced:
#   shared-env.sh   WORKFLOWS_OUT, WORKFLOWS_LIB_DIR and the platform check,
#                   shared with release-env.sh
#   e2e-app.sh      the app under test: identifiers, build outputs, hooks
#   e2e-ios.sh      the simulator a run addresses and its unified-log filter
#   e2e-maestro.sh  flows, the suite bound, the driver-startup timeout and
#                   the check that a suite ran
#   e2e-metro.sh    Metro in the background and the mock API's port
# and then makes the run's side effects once, in workflows_e2e_init.
# shellcheck shell=bash

source "$(dirname "${BASH_SOURCE[0]}")/shared-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/e2e-app.sh"
source "$(dirname "${BASH_SOURCE[0]}")/e2e-ios.sh"
source "$(dirname "${BASH_SOURCE[0]}")/e2e-maestro.sh"
source "$(dirname "${BASH_SOURCE[0]}")/e2e-metro.sh"

# workflows_e2e_init - create $WORKFLOWS_OUT, stamp the run's start and publish
# both to $GITHUB_ENV. Called below, every time this file is sourced: each
# step is a process of its own, and each guard is on the file system, so the
# stamp is made and each variable published once per job.
#
# WORKFLOWS_RUN_START is an immutable "the run started here" stamp.
# collect-forensics.sh needs a fixed instant to select crash reports from, and
# metro.log cannot serve: it is appended throughout the run, so its mtime is
# the last Metro write. Created by whichever script sources this file first,
# then never touched again.
#
# WORKFLOWS_RUN_START_FRESH says "this process created the stamp", i.e. nothing
# ran before it. A collector that stamps the run itself would select nothing at
# all, so it falls back to a time window instead.
workflows_e2e_init() {
  workflows_out_init
  WORKFLOWS_RUN_START="$WORKFLOWS_OUT/run-start"
  WORKFLOWS_RUN_START_FRESH=
  if [ ! -e "$WORKFLOWS_RUN_START" ]; then
    : > "$WORKFLOWS_RUN_START" 2>/dev/null && WORKFLOWS_RUN_START_FRESH=1
  fi
  export WORKFLOWS_RUN_START WORKFLOWS_RUN_START_FRESH
  gh_env_once WORKFLOWS_RUN_START "$WORKFLOWS_RUN_START"
}

workflows_e2e_init
