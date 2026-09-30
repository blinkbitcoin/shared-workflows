#!/usr/bin/env bash
# Shared helpers for scripts/setup/*.sh. Sourced, never run.
#
# Every setup script is idempotent: it checks before it changes anything, so a
# second run on a ready machine only prints "ok" lines. That is what lets CI
# run setup on every fresh runner and a laptop re-run it after an upgrade
# without thinking.
#
# A consumer runs these from the package, from its own root:
#   bash node_modules/@blinkbitcoin/app-tooling/setup/all.sh [--yes] [--boot]
# shellcheck shell=bash

# The repository being set up: the working directory, never this script's own
# location (that is node_modules/ in a consumer). Its .mise.toml, .env.local,
# Makefile, Gemfile and node_modules/ are what the scripts read and write.
SETUP_ROOT="$(pwd -P)"
export SETUP_ROOT

# Where a hint tells the reader to find the other setup scripts. A consumer may
# have no Makefile, so a hint names the script rather than a make target.
SETUP_SCRIPTS="node_modules/@blinkbitcoin/app-tooling/setup"

# The pins (Android command-line tools, the SDK packages, the emulator,
# CocoaPods) live with every other pinned version.
# shellcheck source=scripts/lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

# Seconds between retries; the Nth retry waits N times this. Tests set it to 0.
SETUP_RETRY_DELAY="${SETUP_RETRY_DELAY:-5}"

step() { printf '\n==> %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*" >&2; }
die() {
  printf '  FAIL  %s\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# `darwin` or `linux`; anything else is refused by the scripts that care.
os() { uname -s | tr '[:upper:]' '[:lower:]'; }

# retry <attempts> <command...>: re-runs a flaky network step with a growing
# pause. The Android SDK and Maven downloads reset mid-transfer often enough
# that a single attempt is how a clean machine ends up half-installed.
retry() {
  local attempts="$1" n=1
  shift
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      warn "gave up after $attempts attempts: $*"
      return 1
    fi
    warn "attempt $n of $attempts failed, retrying in $((n * SETUP_RETRY_DELAY))s: $*"
    sleep $((n * SETUP_RETRY_DELAY))
    n=$((n + 1))
  done
}

# consent <what>: an explicit yes is required before anything that accepts a
# licence or downloads gigabytes. SETUP_YES=1 (or --yes) is that yes for CI;
# without it, an interactive terminal is asked and anything else refuses.
consent() {
  [ "${SETUP_YES:-0}" = 1 ] && return 0
  if [ -t 0 ]; then
    local answer
    printf '  ??    %s [y/N] ' "$1"
    read -r answer
    case "$answer" in y | Y | yes | YES) return 0 ;; esac
  fi
  die "not confirmed: $1. Re-run with --yes (or SETUP_YES=1) to agree non-interactively."
}

# set_env_local KEY VALUE: records a per-machine value in .env.local, which
# .mise.toml loads (`_.file`) and derives PATH entries from. Replaces an
# existing KEY line, never duplicates it; the file is gitignored.
set_env_local() {
  local file="$SETUP_ROOT/.env.local" key="$1" value="$2" tmp
  touch "$file"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$file" >"$tmp" || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

# sha_ok <algorithm> <expected> <file>: checksum gate for every download.
sha_ok() {
  local actual
  actual="$(shasum -a "$1" "$3" | cut -d' ' -f1)"
  [ "$actual" = "$2" ] || {
    warn "checksum mismatch for $3: expected $2, got $actual"
    return 1
  }
}

# use_mise_env: puts mise's pinned java/ruby/node first on PATH for the rest of
# the calling script. Needed by sdkmanager (java) and gem (ruby).
use_mise_env() {
  have mise || die "mise is not installed. Run: bash $SETUP_SCRIPTS/toolchain.sh"
  eval "$(cd "$SETUP_ROOT" && mise env --shell bash)"
}

# Common flags. Scripts call `parse_common_args "$@"` and read the globals.
SETUP_BOOT=0
parse_common_args() {
  for arg in "$@"; do
    case "$arg" in
      --yes | -y) SETUP_YES=1 ;;
      --boot) SETUP_BOOT=1 ;;
      *) die "unknown argument: $arg (known: --yes, --boot)" ;;
    esac
  done
  export SETUP_YES SETUP_BOOT
}
