#!/usr/bin/env bash
# mobsfscan over the native projects a release build would compile: a fresh
# Expo prebuild of android/ and ios/, made in a temporary copy of the
# repository, so the working tree's own ios/ and android/ (stale, or absent)
# are never what gets scanned. Reasoned suppressions: .mobsf, when the
# repository has one. Findings do not fail this script.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

sec_enabled mobile
# Expo parses CI as a boolean and throws on an empty string, which is how a
# caller says "not CI" when it cannot unset the variable.
[ -n "${CI:-}" ] || unset CI
sec_require mobsfscan mobile
# SECURITY_EXPO_BIN points the runner at another expo, which is how the tests
# stand in a fake one for the minutes-long real thing.
expo="${SECURITY_EXPO_BIN:-node_modules/.bin/expo}"
[ -x "$expo" ] || {
  if [ -n "${CI:-}" ]; then
    echo "$expo is missing: the mobile job needs dependencies installed, and under CI that is a failure, not a skip" >&2
    exit 1
  fi
  sec_skip mobile "dependencies are not installed (pnpm install)"
  exit 0
}

root="$PWD"
case "$expo" in /*) ;; *) expo="$root/$expo" ;; esac
out="$(cd "$(sec_out_dir)" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rsync -a --exclude node_modules --exclude ios --exclude android --exclude .git --exclude .security "$root/" "$tmp/app"
ln -s "$root/node_modules" "$tmp/app/node_modules"
# APP_VARIANT=production: the variant a release compiles, which is the one
# whose manifest and Info.plist ship.
(cd "$tmp/app" && env APP_VARIANT=production EXPO_NO_GIT_STATUS=1 \
  "$expo" prebuild --platform all --clean --no-install >/dev/null)

# --no-fail: a finding is reported, not thrown. The configuration is named
# outright rather than discovered, and mobsfscan's own warning about a file it
# could not read is turned into a failure: it otherwise carries on with the
# suppressions silently dropped, and every accepted finding comes back as new.
log="$tmp/mobsfscan.log"
# Expanded with ${config[@]+...}: an empty array is "unbound" under set -u in
# bash before 4.4, which is the /bin/bash a Mac runs this with.
config=()
[ ! -f "$root/.mobsf" ] || config=(-c "$root/.mobsf")
(cd "$tmp/app" && mobsfscan --sarif --no-fail ${config[@]+"${config[@]}"} -o "$out/mobile.sarif" android ios) >"$log" 2>&1 || {
  cat "$log" >&2
  exit 1
}
if grep -qE 'Invalid YAML|is not supported|is invalid' "$log"; then
  cat "$log" >&2
  echo "mobsfscan could not read .mobsf, so none of its suppressions applied - fix the file" >&2
  exit 1
fi
echo "mobile: wrote $out/mobile.sarif"
