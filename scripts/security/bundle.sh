#!/usr/bin/env bash
# Export the JavaScript bundle the way a release does and read what it gives
# away: private variable names, credential-shaped strings, cleartext URLs. The
# decisions are security-bundle.mjs's; this only produces the bundle and hands it over.
# Findings do not fail this script.
#
# Platforms come from bundle.platforms (both by default): each platform's
# bundle is its own file, and a string can reach one and not the other.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

sec_enabled bundle
# Expo parses CI as a boolean and throws on an empty string, which is how a
# caller says "not CI" when it cannot unset the variable.
[ -n "${CI:-}" ] || unset CI
# SECURITY_EXPO_BIN points the runner at another expo, which is how the tests
# stand in a fake one for the minutes-long real thing.
expo="${SECURITY_EXPO_BIN:-node_modules/.bin/expo}"
[ -x "$expo" ] || {
  if [ -n "${CI:-}" ]; then
    echo "$expo is missing: the bundle job needs dependencies installed, and under CI that is a failure, not a skip" >&2
    exit 1
  fi
  sec_skip bundle "dependencies are not installed (pnpm install)"
  exit 0
}

platforms="$(sec_setting options.bundle.platforms)"
[ -n "$platforms" ] || {
  sec_skip bundle "bundle.platforms is empty"
  exit 0
}
args=()
IFS=',' read -r -a list <<<"$platforms"
for platform in "${list[@]}"; do
  args+=(--platform "$platform")
done

out="$(sec_out_dir)"
export_dir="$(mktemp -d)"
trap 'rm -rf "$export_dir"' EXIT
# The binary itself, not `pnpm exec`: pnpm may decide to install first.
"$expo" export "${args[@]}" --output-dir "$export_dir" >/dev/null

# Hermes bytecode when the platform builds it, plain JavaScript otherwise.
bundles=()
while IFS= read -r file; do
  bundles+=("$file")
done < <(find "$export_dir/_expo/static/js" -type f \( -name '*.hbc' -o -name '*.js' \) 2>/dev/null | sort)
[ "${#bundles[@]}" -gt 0 ] || {
  echo "expo export wrote no bundle under $export_dir/_expo/static/js" >&2
  exit 1
}

node "$SECURITY_LIB/security-bundle.mjs" "${bundles[@]}" > "$out/bundle.sarif"
echo "bundle: scanned ${#bundles[@]} bundle(s), wrote $out/bundle.sarif"
