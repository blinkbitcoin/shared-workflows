#!/usr/bin/env bash
# Install (or verify) Maestro CLI at the pinned version, then put it on PATH.
#
# From the release archive, verified against its pinned SHA-256 - not the
# curl|bash installer at get.maestro.mobile.dev. That script is fetched fresh
# on every install, so whatever it says at the time runs on the runner, and
# nothing checks the archive it then downloads. The consumer template has
# installed from the checksummed archive on laptops all along.
#
# MAESTRO_DIR is where it goes (default ~/.maestro); a laptop that keeps it
# elsewhere, or a test, points it there. @blinkbitcoin/app-tooling ships this
# script as ci/maestro-install.sh, so a consumer's `make setup-maestro` installs
# the same checksummed archive CI does.
#
# MAESTRO_VERSION and MAESTRO_SHA256 may be overridden by the caller's
# environment even though versions.sh also exports defaults -- capture any
# pre-set value first so sourcing versions.sh below doesn't clobber it. A
# version other than the pinned one needs its own MAESTRO_SHA256.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
_maestro_version_override="${MAESTRO_VERSION:-}"
_maestro_sha_override="${MAESTRO_SHA256:-}"
source "$(dirname "$0")/../lib/versions.sh"
pinned_version="$MAESTRO_VERSION"
if [ -n "$_maestro_version_override" ]; then
  MAESTRO_VERSION="$_maestro_version_override"
fi
if [ -n "$_maestro_sha_override" ]; then
  MAESTRO_SHA256="$_maestro_sha_override"
elif [ "$MAESTRO_VERSION" != "$pinned_version" ]; then
  # The pinned checksum belongs to the pinned version: another version's
  # archive can only fail it, and skipping the check is the hole this closes.
  die "Maestro $MAESTRO_VERSION is not the pinned $pinned_version: pass its release archive's SHA-256 as MAESTRO_SHA256 (maestro-sha256 in test-e2e.yml)"
fi
require_cmd curl unzip

# Maestro prints a first-run analytics notice before anything else, so ask it
# not to - which also stops CI reporting telemetry on every run.
export MAESTRO_CLI_NO_ANALYTICS=1

home="${MAESTRO_DIR:-$HOME/.maestro}"
bin="$home/bin/maestro"

# The first dotted number in the output, not the whole output. Comparing the
# whole string worked on any machine where maestro had run once and failed on
# every fresh runner, where the notice above is printed and the check reported
# `expected 2.10.0, got Anonymous analytics enabled...`. The env var alone
# would fix today's banner; parsing is what survives the next one.
maestro_version() {
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

installed_version() {
  [ -x "$bin" ] || return 1
  maestro_version "$bin"
}

if [ "$(installed_version || true)" != "$MAESTRO_VERSION" ]; then
  group "Download and install Maestro $MAESTRO_VERSION"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  url="https://github.com/mobile-dev-inc/maestro/releases/download/cli-${MAESTRO_VERSION}/maestro.zip"
  curl -fsSL --retry 3 --retry-delay 2 -o "$work/maestro.zip" "$url" ||
    die "could not download Maestro $MAESTRO_VERSION from $url"
  actual="$(sha256_file "$work/maestro.zip")"
  [ "$actual" = "$MAESTRO_SHA256" ] ||
    die "refusing an unverified Maestro download: sha256 $actual, expected $MAESTRO_SHA256"
  unzip -q "$work/maestro.zip" -d "$work" || die "the Maestro archive did not unzip"
  if [ ! -d "$work/maestro/bin" ] || [ ! -d "$work/maestro/lib" ]; then
    die "the Maestro archive holds no maestro/bin and maestro/lib"
  fi
  mkdir -p "$home"
  rm -rf "${home:?}/bin" "${home:?}/lib"
  mv "$work/maestro/bin" "$work/maestro/lib" "$home/"
  endgroup
fi

[ -x "$bin" ] || die "maestro install failed: $bin not found"
installed="$(maestro_version "$bin")"
[ "$installed" = "$MAESTRO_VERSION" ] ||
  die "maestro version mismatch: expected $MAESTRO_VERSION, got $installed"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$home/bin" >> "$GITHUB_PATH"
fi
