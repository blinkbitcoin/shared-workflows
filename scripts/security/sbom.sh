#!/usr/bin/env bash
# A CycloneDX software bill of materials for everything pnpm-lock.yaml pins,
# written next to the SARIF as sbom.cdx.json. It is a record, not a scan: the
# SARIF it leaves is a clean run whose note says how many components the bill
# lists, and the production dispatch keeps the file as a workflow artifact so
# a later advisory can be checked against exactly what shipped.
#
# --lockfile-only reads pnpm-lock.yaml alone, so this needs no node_modules and
# answers the same on a laptop and on a runner that never installed.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

sec_enabled sbom
sec_require pnpm sbom

out="$(sec_out_dir)"
bom="$out/sbom.cdx.json"
pnpm sbom --sbom-format cyclonedx --sbom-type application --lockfile-only --out "$bom" >/dev/null

# A bill that lists nothing is a broken run, not a clean one: the lockfile
# always pins something, so zero components means pnpm read the wrong file.
node "$SECURITY_LIB/security-sarif.mjs" bom sbom "$bom" > "$out/sbom.sarif"
echo "sbom: wrote $bom and $out/sbom.sarif"
