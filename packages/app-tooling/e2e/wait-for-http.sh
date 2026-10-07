#!/usr/bin/env bash
# Wait until an HTTP server answers.
#
# A server that is listening but still starting up refuses the connection, and one
# that is up answers with a status - any status. That is all this asks: a mock API
# does not need a health route for a suite to know it is there, and a status of
# 404 or 405 from a GraphQL endpoint probed with a GET is still an answer.
#
# Usage: wait-for-http.sh URL [SECONDS]     (default 60 real seconds, one try a second)
# Exits 0 as soon as the server answers, 1 when it never did.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd curl

url="${1:?usage: wait-for-http.sh URL [SECONDS]}"
seconds="${2:-60}"
[[ "$seconds" =~ ^[0-9]+$ ]] || die "wait-for-http: SECONDS must be a whole number, got '$seconds'"

answers() { curl -sS -o /dev/null --max-time 2 "$url" 2>/dev/null; }

# Bounded by the clock, not by a count of tries: each try is up to 2s of curl
# on top of the 1s between tries, so 60 tries were up to 180s.
wait_until "$seconds" 1 answers ||
  die "nothing answered at $url within ${seconds}s (gave up after ${wait_until_elapsed}s)"
