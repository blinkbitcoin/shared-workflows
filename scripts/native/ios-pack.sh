#!/usr/bin/env bash
# Pack the simulator .app into a tar for upload-artifact. A tar (not the raw
# directory) because upload-artifact does not preserve the executable bit or
# symlinks inside a .app bundle, and an unpacked app then refuses to launch.
# Needs: ios-build.sh. Output: $WORKFLOWS_OUT/<scheme>.app.tar
# Usage: ios-pack.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

root="$(consumer_root)"
cd "$root"
scheme="$(workflows_ios_scheme)"
[ -d "$WORKFLOWS_IOS_PRODUCTS_DIR/$scheme.app" ] || die "no $WORKFLOWS_IOS_PRODUCTS_DIR/$scheme.app - run ios-build.sh first"

tar_path="$WORKFLOWS_OUT/$scheme.app.tar"
group "Pack the simulator app"
tar -C "$WORKFLOWS_IOS_PRODUCTS_DIR" -cf "$tar_path" "$scheme.app"
endgroup
log "packed $tar_path ($(du -h "$tar_path" | cut -f1))"
gh_output app_tar "$tar_path"
