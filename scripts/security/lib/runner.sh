#!/usr/bin/env bash
# Shared rules for every security runner. Source it, do not execute it.
# shellcheck shell=bash
#
# Sourcing it also moves into the repository being scanned (consumer_root: the
# workflow's working directory in CI, the current directory on a laptop) and
# sets SECURITY_LIB to the directory holding the security-*.mjs modules. It
# runs from two places, and the one relative path that differs is probed:
#
#   scripts/security/lib/runner.sh            here, in the workflows checkout;
#                                             the modules are in packages/app-tooling/lib
#   <package>/security/lib/runner.sh          the copy @blinkbitcoin/app-tooling ships;
#                                             the modules are in <package>/lib
#
#   - Output goes to $SECURITY_DIR (default .security), one <job>.sarif each.
#   - A disabled job writes a skipped SARIF and exits 0.
#   - A missing tool is a skip locally and a failure under CI, so "skipped"
#     can never pass for "clean" in the pipeline.
#   - A finding never fails the runner. Only the verdict fails on findings.

_security_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$_security_here/../../lib/common.sh"
if [ -f "$_security_here/../../lib/security-sarif.mjs" ]; then
  SECURITY_LIB="$(cd "$_security_here/../../lib" && pwd -P)"
else
  SECURITY_LIB="$(cd "$_security_here/../../../packages/app-tooling/lib" && pwd -P)"
fi
export SECURITY_LIB
_security_root="$(consumer_root)" || exit 1
cd "$_security_root" || exit 1

sec_out_dir() {
  local dir="${SECURITY_DIR:-.security}"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Writes the skipped SARIF for a job and leaves the caller to exit 0.
sec_skip() {
  local job="$1" reason="$2" dir
  dir="$(sec_out_dir)"
  node "$SECURITY_LIB/security-sarif.mjs" skip "$job" "$reason" > "$dir/$job.sarif"
  echo "::notice::$job skipped: $reason"
}

# Exits the runner early when the job is switched off. An invalid setting
# (a malformed security-settings.json, or a SECURITY_* value the resolver cannot
# parse) must fail the run, never read as "disabled" - the command
# substitution below would otherwise swallow settings.mjs's own nonzero exit
# and `[ "" = "true" ]` would silently take the skip branch.
sec_enabled() {
  local job="$1" value
  if ! value="$(node "$SECURITY_LIB/security-settings.mjs" get "jobs.$job")"; then
    echo "security-settings.mjs failed resolving jobs.$job - security-settings.json or a SECURITY_* value is invalid (see the error above); that fails the run, it does not disable it" >&2
    exit 1
  fi
  [ "$value" = "true" ] && return 0
  sec_skip "$job" "disabled in security-settings.json or the environment"
  exit 0
}

# A tool the runner cannot work without.
sec_require() {
  local tool="$1" job="$2"
  command -v "$tool" >/dev/null 2>&1 && return 0
  if [ -n "${CI:-}" ]; then
    echo "$tool is not installed, and under CI that is a failure, not a skip" >&2
    exit 1
  fi
  sec_skip "$job" "$tool is not installed (mise install)"
  exit 0
}

# One resolved setting, for a runner's options and the llm block:
#
#   hosts="$(sec_setting options.bundle.hosts)"      # a list comes comma-joined
#
# The same fail-loudly rule as sec_enabled: an invalid value is the run's
# failure, never an empty string a runner would quietly read as "none".
sec_setting() {
  local key="$1" value
  if ! value="$(node "$SECURITY_LIB/security-settings.mjs" get "$key")"; then
    echo "security-settings.mjs failed resolving $key - security-settings.json or a SECURITY_* value is invalid (see the error above); that fails the run" >&2
    exit 1
  fi
  printf '%s' "$value"
}

# The newest Android SDK build-tools copy of a tool (aapt2, apksigner), or the
# one on PATH. Prints an absolute path, or fails when there is none.
sec_android_build_tool() {
  local tool="$1" sdk newest candidate
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return 0
  fi
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [ -n "$sdk" ] && [ -d "$sdk/build-tools" ] || return 1
  newest="$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -V | tail -1 || true)"
  [ -n "$newest" ] || return 1
  candidate="$sdk/build-tools/$newest/$tool"
  [ -x "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}
