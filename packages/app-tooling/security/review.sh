#!/usr/bin/env bash
# The LLM security review of the change - security-review.mjs does the work and decides
# every skip; this only checks the switch and the tool. Off by default: it
# sends the diff to the configured provider. See the check-security.yml section of docs/consumer-guide.md.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

sec_enabled review
sec_require git review

out="$(sec_out_dir)"
node "$SECURITY_LIB/security-review.mjs" > "$out/review.sarif"
echo "review: wrote $out/review.sarif"
