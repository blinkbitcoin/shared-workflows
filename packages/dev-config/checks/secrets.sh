#!/usr/bin/env bash
# Scan the consumer's whole git history for committed secrets with gitleaks.
# History, not the working tree: a key committed and deleted in a later commit
# is still in the repository, and still needs rotating. A consumer's
# .gitleaks.toml (and .gitleaksignore) at its root is picked up by gitleaks
# itself; this script adds no allowlist of its own.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/versions.sh"
require_cmd git mise

root="$(consumer_root)"
cd "$root"

# A shallow clone scans only the commits it has, which reads as a clean history
# when it is not one. The check-code workflow fetches everything for this step.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  die "secrets.sh: $root is a shallow clone, so the history scan would miss commits - check out with fetch-depth: 0"
fi

mise x "gitleaks@$GITLEAKS_VERSION" -- gitleaks git --redact --no-banner .
