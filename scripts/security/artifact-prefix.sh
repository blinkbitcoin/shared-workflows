#!/usr/bin/env bash
# Check check-security.yml's artifact-prefix input and publish the stem every
# artifact name of this call starts with.
#
# Usage: artifact-prefix.sh [PREFIX]
#
# Artifacts are scoped to the workflow run, not to the called workflow, so two
# calls of check-security.yml in one run share one namespace: without a prefix
# the second call's uploads collide with the first's, and its verdict, which
# downloads security-sarif-*, merges the other call's SARIF into its own.
#
# An empty prefix publishes an empty stem, so a caller that passes none keeps
# the names it always had (security-sarif-code). A non-empty one publishes
# PREFIX- (my-app-security-sarif-code). The rule below is what keeps each call's
# download pattern, <stem>security-sarif-*, matching its own artifacts only:
#   - lowercase letters, digits and inner hyphens, so the stem carries no glob
#     character (* ? [ ] { } !) into the download pattern and no character an
#     artifact name refuses;
#   - no "security-sarif" anywhere: a prefix such as security-sarif-x would make
#     the unprefixed call's security-sarif-* match x-security-sarif-code, and
#     every way one call's pattern can match another call's names needs that
#     text inside the longer prefix;
#   - at most 64 characters, well inside the artifact name limit.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

prefix="${1:-}"
if [ -z "$prefix" ]; then
  gh_output artifact-prefix ''
  log "security: artifact-prefix is empty, artifacts keep their plain names (security-sarif-<job>)"
  exit 0
fi

fix="pass lowercase letters, digits and hyphens, starting and ending with a letter or digit, at most 64 characters, without the text security-sarif - for example artifact-prefix: my-app"
if [ "${#prefix}" -gt 64 ]; then
  die_fix "artifact-prefix '$prefix' is ${#prefix} characters long" "$fix" check-securityyml
fi
if ! [[ "$prefix" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  die_fix "artifact-prefix '$prefix' is not a plain name" "$fix" check-securityyml
fi
case "$prefix" in
  *security-sarif*)
    die_fix "artifact-prefix '$prefix' contains security-sarif, so another call's download pattern could match this call's artifacts" "$fix" check-securityyml
    ;;
esac

gh_output artifact-prefix "$prefix-"
log "security: artifacts of this call are named $prefix-security-sarif-<job>"
