#!/usr/bin/env bash
# Free disk space on a Linux GitHub-hosted runner before a large native build.
# A no-op anywhere else: the runner images differ enough that there is
# nothing safe or useful to prune, and an iOS/macOS caller should be able to
# call this unconditionally without a platform check of its own. Guarded on
# GITHUB_ACTIONS+RUNNER_OS (not just `uname -s`) so this never runs its
# destructive rm/docker-prune path on a developer's own Linux machine by
# accident. Set WORKFLOWS_FORCE_RUNNER_SCRIPTS=1 to bypass the guard for deliberate
# local/self-hosted testing.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if [ "${WORKFLOWS_FORCE_RUNNER_SCRIPTS:-}" != "1" ] &&
   { [ "${GITHUB_ACTIONS:-}" != "true" ] || [ "${RUNNER_OS:-}" != "Linux" ]; }; then
  log "free-disk: not a Linux GitHub Actions runner (GITHUB_ACTIONS=${GITHUB_ACTIONS:-}, RUNNER_OS=${RUNNER_OS:-}); nothing to free, skipping"
  exit 0
fi

group "Free disk space"
df -h /

sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/.ghcup

ndk_dir="/usr/local/lib/android/sdk/ndk"
if [ -d "$ndk_dir" ]; then
  latest=$(find "$ndk_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1)
  find "$ndk_dir" -mindepth 1 -maxdepth 1 -type d ! -name "$latest" -print0 |
    xargs -0 -r sudo rm -rf
fi

if command -v docker >/dev/null 2>&1; then
  sudo docker image prune -af || true
fi

df -h /
endgroup
