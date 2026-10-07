#!/usr/bin/env bash
# Publish the release output directories to $GITHUB_ENV up front, so an
# upload/download step's `path:` resolves even when an earlier step failed
# before any other release script ran (the same reason
# scripts/e2e/env-publish.sh exists for the E2E jobs).
#
# It does not publish WORKFLOWS_DIR. scripts/ci/workflows-env.sh does, from the
# Setup action's "Export WORKFLOWS_DIR environment" step, and every release job
# runs this step before Setup, so WORKFLOWS_DIR is normally still unset here.
# The log says so, to send whoever is chasing an empty WORKFLOWS_DIR (exit 127
# on `bash "$WORKFLOWS_DIR/..."`, as in v0.6.0) to the step that publishes it.
# A WORKFLOWS_DIR that is set but is not a directory is always wrong, so that
# fails here, before anything is published.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if [ -z "${WORKFLOWS_DIR:-}" ]; then
  log "WORKFLOWS_DIR is not published yet: this step publishes only the release output directories; the Setup action's \"Export WORKFLOWS_DIR environment\" step publishes WORKFLOWS_DIR, and until it runs a step reaches the scripts through .workflows/"
elif [ ! -d "$WORKFLOWS_DIR" ]; then
  die_fix "WORKFLOWS_DIR is '$WORKFLOWS_DIR', which is not a directory, so every later step that runs bash \"\$WORKFLOWS_DIR/...\" fails with exit 127" \
    "WORKFLOWS_DIR belongs to scripts/ci/workflows-env.sh, which the Setup action's \"Export WORKFLOWS_DIR environment\" step runs and which sets it to \$GITHUB_WORKSPACE/.workflows; remove whatever else sets it in this job, and check that the \"Checkout shared-workflows\" step checked this repository out into .workflows" \
    gotchas-encoded
else
  log "WORKFLOWS_DIR=$WORKFLOWS_DIR"
fi

source "$(dirname "$0")/../lib/release-env.sh"

log "WORKFLOWS_OUT=$WORKFLOWS_OUT"
log "WORKFLOWS_OUTPUT_DIR=$WORKFLOWS_OUTPUT_DIR"
log "WORKFLOWS_RELEASE_META_DIR=$WORKFLOWS_RELEASE_META_DIR"
log "WORKFLOWS_OTA_DIR=$WORKFLOWS_OTA_DIR"
log "WORKFLOWS_ASSETS_DIR=$WORKFLOWS_ASSETS_DIR"
