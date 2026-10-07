#!/usr/bin/env bash
# It does not publish WORKFLOWS_DIR. scripts/ci/workflows-env.sh does, from the
# Setup action's "Export WORKFLOWS_DIR environment" step and from test-e2e.yml
# build-ios's own "Publish WORKFLOWS_DIR" step. Only build-ios runs that before
# this step; the ios and android jobs run this before Setup, so WORKFLOWS_DIR is
# still unset there. The log says which, to send whoever is chasing an empty
# WORKFLOWS_DIR (exit 127 on `bash "$WORKFLOWS_DIR/..."`) to the step that
# publishes it. A WORKFLOWS_DIR that is set but is not a directory is always
# wrong, so that fails here, before anything is published.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if [ -z "${WORKFLOWS_DIR:-}" ]; then
  log "WORKFLOWS_DIR is not published yet: this step publishes only the E2E output directory and run start; the Setup action's \"Export WORKFLOWS_DIR environment\" step publishes WORKFLOWS_DIR, and until it runs a step reaches the scripts through .workflows/"
elif [ ! -d "$WORKFLOWS_DIR" ]; then
  die_fix "WORKFLOWS_DIR is '$WORKFLOWS_DIR', which is not a directory, so every later step that runs bash \"\$WORKFLOWS_DIR/...\" fails with exit 127" \
    "WORKFLOWS_DIR belongs to scripts/ci/workflows-env.sh, which the Setup action's \"Export WORKFLOWS_DIR environment\" step (and test-e2e.yml build-ios's \"Publish WORKFLOWS_DIR\" step) runs and which sets it to \$GITHUB_WORKSPACE/.workflows; remove whatever else sets it in this job, and check that the \"Checkout shared-workflows\" step checked this repository out into .workflows" \
    gotchas-encoded
else
  log "WORKFLOWS_DIR=$WORKFLOWS_DIR"
fi

source "$(dirname "$0")/../lib/e2e-env.sh"

# Sourcing e2e-env.sh is the whole point: it publishes WORKFLOWS_OUT and WORKFLOWS_RUN_START
# to $GITHUB_ENV (once per job) so later `with:` blocks can use ${{ env.WORKFLOWS_OUT }}
# before any other script in the family has run.
log "WORKFLOWS_OUT=$WORKFLOWS_OUT"
log "WORKFLOWS_RUN_START=$WORKFLOWS_RUN_START"
