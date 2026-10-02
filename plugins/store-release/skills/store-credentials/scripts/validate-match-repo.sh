#!/bin/bash
# Check that a fastlane match certificates repository is reachable before
# wiring MATCH_GIT_URL / MATCH_GIT_BASIC_AUTHORIZATION into GitHub, and
# refuse outright if the url given is the production repo recorded in
# store-setup's state (that one is not for rehearsing against).
#
# Usage: validate-match-repo.sh --git-url <url>
#
#   MATCH_GIT_BASIC_AUTHORIZATION  optional; the base64 of `user:token` for
#                                  an https match url, read from the
#                                  environment and handed to git through
#                                  GIT_CONFIG_COUNT/GIT_CONFIG_KEY_0/
#                                  GIT_CONFIG_VALUE_0 so it never appears in
#                                  git's argv or a process listing. There is
#                                  deliberately no --basic-auth option.
#   STORE_SETUP_DIR / REPO_ROOT    same defaults as store-setup/scripts/state.sh
#
# Exit codes: 0 reachable, 1 not reachable, 2 refused (production url), 64 usage.

set -uo pipefail

die_usage() { echo "FATAL: $*" >&2; exit 64; }

GIT_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --git-url)
      [ $# -ge 2 ] || die_usage "--git-url needs a value"
      GIT_URL="$2"
      shift 2
      ;;
    --basic-auth)
      die_usage "--basic-auth is not accepted - a credential must not reach git's argv; set MATCH_GIT_BASIC_AUTHORIZATION in the environment instead"
      ;;
    *)
      die_usage "unknown option '$1'"
      ;;
  esac
done

[ -n "$GIT_URL" ] || die_usage "--git-url is required"

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "${STORE_SETUP_DIR:-}" ] && [ -n "$REPO_ROOT" ]; then
  STORE_SETUP_DIR="$REPO_ROOT/.store-setup"
fi
STATE_FILE="${STORE_SETUP_DIR:-}/state.json"

if [ -n "${STORE_SETUP_DIR:-}" ] && [ -f "$STATE_FILE" ]; then
  PRODUCTION_URL="$(node -e '
const fs = require("fs");
try {
  const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(state.facts && state.facts.production_match_git_url ? state.facts.production_match_git_url : "");
} catch (e) {
  process.stdout.write("");
}
' "$STATE_FILE" 2>/dev/null)"
  if [ -n "$PRODUCTION_URL" ] && [ "$PRODUCTION_URL" = "$GIT_URL" ]; then
    echo "FATAL: refused - '$GIT_URL' is the production match repository recorded in $STATE_FILE; this is not for rehearsing against" >&2
    exit 2
  fi
fi

LS_REMOTE_ERR="$(mktemp "${TMPDIR:-/tmp}/validate-match-repo.XXXXXX")"
trap 'rm -f "$LS_REMOTE_ERR"' EXIT INT TERM HUP

# The header value travels in the environment, not in argv: `git -c
# http.extraHeader=...` would put the credential in every process listing.
ls_remote() {
  if [ -n "${MATCH_GIT_BASIC_AUTHORIZATION:-}" ]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
      GIT_CONFIG_VALUE_0="Authorization: Basic $MATCH_GIT_BASIC_AUTHORIZATION" \
      git ls-remote --exit-code "$GIT_URL"
  else
    git ls-remote --exit-code "$GIT_URL"
  fi
}

if ! ls_remote >/dev/null 2>"$LS_REMOTE_ERR"; then
  echo "FAIL: could not reach '$GIT_URL' - $(head -1 "$LS_REMOTE_ERR")" >&2
  exit 1
fi

echo "OK: '$GIT_URL' is reachable"

if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/certs" ]; then
  echo "WARN: $REPO_ROOT/certs already exists - a previous 'fastlane match' run left files there; match will reuse or overwrite them"
fi

exit 0
