#!/usr/bin/env bash
# Export the JavaScript bundle the way a release does and read what it gives
# away: private variable names, credential-shaped strings, cleartext URLs. The
# decisions are security-bundle.mjs's; this only produces the bundle and hands it over.
# Findings do not fail this script.
#
# Platforms come from bundle.platforms (both by default): each platform's
# bundle is its own file, and a string can reach one and not the other.
#
# How the bundle is made depends on the native stack (sec_native_stack):
#
#   expo  `expo export`, which writes Hermes bytecode (.hbc) where the platform
#         builds with Hermes and plain JavaScript otherwise.
#   bare  `react-native bundle`, once per platform, with the release build's
#         flags: --dev false, and --minify only when the platform does not
#         build with Hermes (a Hermes release leaves that to hermesc). Hermes
#         is React Native's default; hermesEnabled=false in
#         android/gradle.properties, or hermes_enabled false in ios/Podfile,
#         switches it off. The React Native CLI writes JavaScript either way and
#         leaves bytecode to the native build, so the scan reads the
#         JavaScript: the same strings hermesc would put in its string table.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

sec_enabled bundle
# Expo parses CI as a boolean and throws on an empty string, which is how a
# caller says "not CI" when it cannot unset the variable.
[ -n "${CI:-}" ] || unset CI
stack="$(sec_native_stack)"
# SECURITY_EXPO_BIN and SECURITY_REACT_NATIVE_BIN point the runner at another
# expo or react-native, which is how the tests stand in a fake one for the
# minutes-long real thing.
if [ "$stack" = expo ]; then
  tool="${SECURITY_EXPO_BIN:-node_modules/.bin/expo}"
else
  tool="${SECURITY_REACT_NATIVE_BIN:-node_modules/.bin/react-native}"
fi
[ -x "$tool" ] || {
  if [ -n "${CI:-}" ]; then
    echo "$tool is missing: the bundle job needs dependencies installed, and under CI that is a failure, not a skip" >&2
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
IFS=',' read -r -a list <<<"$platforms"

out="$(sec_out_dir)"
export_dir="$(mktemp -d)"
trap 'rm -rf "$export_dir"' EXIT

# Whether a bare app builds PLATFORM (android or ios) with Hermes.
hermes_enabled() {
  local file pattern
  if [ "$1" = android ]; then
    file=android/gradle.properties
    pattern='^[[:space:]]*hermesEnabled[[:space:]]*=[[:space:]]*false'
  else
    file=ios/Podfile
    pattern="hermes_enabled[\"']?[[:space:]]*(=>|:)[[:space:]]*false"
  fi
  if grep -Eq "$pattern" "$file" 2>/dev/null; then return 1; fi
  return 0
}

# The entry file a bare app's native build bundles: index.<platform>.js when
# there is one, as React Native's own build scripts prefer, else index.js or
# its TypeScript twin.
entry_file() {
  local candidate
  for candidate in "index.$1.js" index.js index.ts index.tsx; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

bundles=()
if [ "$stack" = expo ]; then
  args=()
  for platform in "${list[@]}"; do
    args+=(--platform "$platform")
  done
  # The binary itself, not `pnpm exec`: pnpm may decide to install first.
  "$tool" export "${args[@]}" --output-dir "$export_dir" >/dev/null

  # Hermes bytecode when the platform builds it, plain JavaScript otherwise.
  while IFS= read -r file; do
    bundles+=("$file")
  done < <(find "$export_dir/_expo/static/js" -type f \( -name '*.hbc' -o -name '*.js' \) 2>/dev/null | sort)
  [ "${#bundles[@]}" -gt 0 ] || {
    echo "expo export wrote no bundle under $export_dir/_expo/static/js" >&2
    exit 1
  }
else
  for platform in "${list[@]}"; do
    entry="$(entry_file "$platform")" || {
      echo "no index.$platform.js, index.js, index.ts or index.tsx: the bare stack bundles the entry file the native build does, and this repository has none" >&2
      exit 1
    }
    minify=true
    if hermes_enabled "$platform"; then minify=false; fi
    file="$export_dir/$platform/index.$platform.bundle"
    mkdir -p "$export_dir/$platform/assets"
    "$tool" bundle --platform "$platform" --dev false --minify "$minify" --entry-file "$entry" \
      --bundle-output "$file" --assets-dest "$export_dir/$platform/assets" >/dev/null
    [ -s "$file" ] || {
      echo "react-native bundle wrote no $file" >&2
      exit 1
    }
    bundles+=("$file")
  done
fi

node "$SECURITY_LIB/security-bundle.mjs" "${bundles[@]}" > "$out/bundle.sarif"
echo "bundle: scanned ${#bundles[@]} bundle(s) of the $stack stack, wrote $out/bundle.sarif"
