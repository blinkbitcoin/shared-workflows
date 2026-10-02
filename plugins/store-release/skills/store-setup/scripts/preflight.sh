#!/bin/bash
# Check that everything the store-setup checklist and its scripts need is on
# PATH and authenticated, before spending a human's time on the console work.
#
# Usage: preflight.sh [--json]
#
#   Required: git, node, gh (logged in, repo resolves), bundle (with fastlane
#   runnable), openssl, base64. Missing any of these fails the run.
#
#   Warn only (do not fail): keytool (Android keystore inspection), and one of
#   sips/magick (store image resizing) — needed only for steps that touch
#   images or keystores, so their absence is noted, not fatal.
#
# Exit codes: 0 ok, 1 a required tool/check failed, 64 usage.

set -uo pipefail

JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    *)
      echo "FATAL: unknown option '$a'" >&2
      exit 64
      ;;
  esac
done

FAIL=0
ROWS=() # each row: tool|found(0/1)|required(0/1)|why

add_row() {
  ROWS+=("$1|$2|$3|$4")
  if [ "$3" = "1" ] && [ "$2" = "0" ]; then FAIL=1; fi
}

check_cmd() {
  local name="$1" required="$2" why="$3"
  if command -v "$name" >/dev/null 2>&1; then
    add_row "$name" 1 "$required" "$why"
  else
    add_row "$name" 0 "$required" "$why"
  fi
}

check_cmd git 1 "version control"
check_cmd node 1 "runs the state.sh JSON helper"
check_cmd gh 1 "GitHub CLI: variables, secrets, environments"
check_cmd bundle 1 "Ruby bundler: runs fastlane"
check_cmd openssl 1 "certificate and keystore handling"
check_cmd base64 1 "encoding secrets for gh secret set"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  add_row "gh-auth" 1 1 "gh must be logged in"
else
  add_row "gh-auth" 0 1 "gh must be logged in"
fi

if command -v gh >/dev/null 2>&1 && gh repo view --json nameWithOwner >/dev/null 2>&1; then
  add_row "gh-repo" 1 1 "the repo must resolve on GitHub"
else
  add_row "gh-repo" 0 1 "the repo must resolve on GitHub"
fi

# No `grep` dependency here on purpose: preflight is what checks the
# environment is usable at all, so it should not assume anything beyond the
# tools it itself lists as required.
FASTLANE_VERSION=""
if command -v bundle >/dev/null 2>&1; then
  FASTLANE_VERSION="$(bundle exec fastlane --version 2>/dev/null)"
fi
case "$FASTLANE_VERSION" in
  *[Ff]astlane*) add_row "fastlane" 1 1 "runs the release lanes" ;;
  *) add_row "fastlane" 0 1 "runs the release lanes" ;;
esac

check_cmd keytool 0 "Android keystore inspection (warn only)"

if command -v sips >/dev/null 2>&1 || command -v magick >/dev/null 2>&1; then
  add_row "sips-or-magick" 1 0 "store image resizing (warn only)"
else
  add_row "sips-or-magick" 0 0 "store image resizing (warn only)"
fi

if [ "$JSON" -eq 1 ]; then
  first=1
  printf '['
  for r in "${ROWS[@]}"; do
    IFS='|' read -r name found required why <<<"$r"
    [ "$first" -eq 1 ] || printf ','
    first=0
    found_bool=$([ "$found" = 1 ] && echo true || echo false)
    required_bool=$([ "$required" = 1 ] && echo true || echo false)
    printf '{"tool":"%s","found":%s,"required":%s,"why":"%s"}' "$name" "$found_bool" "$required_bool" "$why"
  done
  printf ']\n'
else
  printf '%-16s %-6s %s\n' "tool" "found" "why"
  for r in "${ROWS[@]}"; do
    IFS='|' read -r name found _required why <<<"$r"
    printf '%-16s %-6s %s\n' "$name" "$([ "$found" = 1 ] && echo yes || echo no)" "$why"
  done
fi

exit "$FAIL"
