#!/usr/bin/env bash
# CocoaPods install for the prebuilt ios/ tree. Uses Bundler when the consumer
# pins CocoaPods in a Gemfile (the Expo template default), plain `pod` otherwise
# -- a repo without a Gemfile has no bundle to exec.
# Usage: pods.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

root="$(consumer_root)"
[ -d "$root/ios" ] || die "no ios/ in $root - run prebuild.sh ios first"
cd "$root/ios"

# Three attempts, 20 seconds apart: the specs CDN and the hosts a pod's source
# is fetched from fail now and then for a few seconds, and that should not cost
# a release. `pod install` is safe to repeat - it resolves against Podfile.lock
# and rewrites Pods/ to match, whatever an interrupted run left there. A real
# error (a broken Podfile) fails the same way three times, 40 seconds later.
export COCOAPODS_DISABLE_STATS=1
group "pod install"
if [ -f "$root/Gemfile" ] && command -v bundle >/dev/null 2>&1; then
  retry_command 3 20 -- bundle exec pod install
else
  require_cmd pod
  retry_command 3 20 -- pod install
fi
endgroup

# The first lines carry the pod count and the first resolved versions - enough
# to tell a cache hit from a real resolve in the log.
log "Podfile.lock (first 5 lines):"
head -5 Podfile.lock >&2
