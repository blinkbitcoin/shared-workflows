#!/usr/bin/env bash
# Shared helpers for every script in this repo. Source it; do not execute.
# shellcheck shell=bash
log() { printf '%s\n' "$*" >&2; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }
# die_fix WHAT FIX [ANCHOR] - die with the remediation and the contract beside it.
#
# `die` is right for a failure whose fix is obvious from the message, and most
# of the ~140 in this repo are exactly that. This is for the other kind: the
# boundary where the consumer's repository does not provide something this
# family needs. There the reader is often adopting these workflows, may never
# have seen this repo, and "missing command: pnpm" is a true sentence that does
# not help - the fix is a file they have not written yet.
#
# One annotation, not three. A GitHub annotation renders `%0A` as a line break,
# so the whole thing stays attached to the step that failed instead of
# scattering notices elsewhere in the log. `%25` first: the encoding is
# percent-based, so escaping the percent sign after the newlines would eat them.
die_fix() {
  local what="$1" fix="$2" anchor="${3:-}"
  local url="https://github.com/blinkbitcoin/shared-workflows/blob/v0/docs/consumer-guide.md"
  [ -n "$anchor" ] && url="$url#$anchor"
  local body="$what
Fix: $fix
Contract: $url"
  body="${body//\%/%25}"
  body="${body//$'\n'/%0A}"
  printf '::error::%s\n' "$body" >&2
  exit 1
}
group() { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }
gh_output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; else printf '%s=%s\n' "$1" "$2"; fi; }
# gh_env_multiline KEY VALUE - append KEY to $GITHUB_ENV in the heredoc
# delimiter form, the only form that is safe for a value the caller controls.
#
# `$GITHUB_ENV` is line-based: `KEY=<value with a newline in it>` writes a
# *second* line, and the runner reads that line as another variable, set for
# every later step in the job. A value like `a\nPATH=/evil` therefore replaces
# PATH in a job that also holds signing credentials. The heredoc form has no
# such reading: everything between the two delimiter lines is the value.
#
# The delimiter carries $RANDOM so it cannot be predicted from the outside, and
# a value that contains it anyway is fatal rather than silently truncated.
gh_env_multiline() {
  local key="$1" value="$2" delim
  delim="__workflows_eof_${RANDOM}${RANDOM}"
  case "$value" in
    *"$delim"*) die "value for $key contains the generated heredoc delimiter - refusing to write it to \$GITHUB_ENV" ;;
  esac
  if [ -n "${GITHUB_ENV:-}" ]; then
    { printf '%s<<%s\n' "$key" "$delim"; printf '%s\n' "$value"; printf '%s\n' "$delim"; } >> "$GITHUB_ENV"
  fi
  export "$key=$value"
}
# gh_env KEY VALUE - publish KEY for every later step in the job. A value that
# would break the line-based form is routed through gh_env_multiline, so no
# caller has to know whether its value can contain a newline.
gh_env() {
  case "$2" in
    *$'\n'* | *$'\r'*) gh_env_multiline "$1" "$2"; return ;;
  esac
  if [ -n "${GITHUB_ENV:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"; fi
  export "$1=$2"
}
# gh_env_once KEY VALUE - like gh_env, but only appends to $GITHUB_ENV when no
# "KEY=" line already exists there. File-based, so it dedupes across the many
# separate steps (each its own process) that may source the same env-setup
# library within one job, not just within one process.
gh_env_once() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    # Both forms count as "already there": gh_env may have written either.
    grep -q -e "^$1=" -e "^$1<<" "$GITHUB_ENV" 2>/dev/null || gh_env "$1" "$2"
  fi
  export "$1=$2"
}
# consumer_root is canonical (pwd -P) on purpose: cache `path:` matching and tar operations need stable absolute paths.
consumer_root() { local base="${GITHUB_WORKSPACE:-$PWD}"; local wd="${WORKING_DIRECTORY:-.}"; cd "$base/$wd" && pwd -P; }
require_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done; }
