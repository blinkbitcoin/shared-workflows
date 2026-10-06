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
  local key="$1" value="$2"
  new_heredoc_delimiter "$key" "$value" GITHUB_ENV
  if [ -n "${GITHUB_ENV:-}" ]; then
    { printf '%s<<%s\n' "$key" "$heredoc_delimiter"; printf '%s\n' "$value"; printf '%s\n' "$heredoc_delimiter"; } >> "$GITHUB_ENV"
  fi
  export "$key=$value"
}
# gh_output_multiline KEY VALUE - gh_output for a value that may span lines:
# the same heredoc delimiter form, into $GITHUB_OUTPUT when it is set and onto
# stdout when it is not, as gh_output does. `$GITHUB_OUTPUT` is line-based
# exactly like `$GITHUB_ENV`, so a bare `KEY=value` would cut the value at its
# first newline and read the rest as more outputs.
gh_output_multiline() {
  local key="$1" value="$2"
  new_heredoc_delimiter "$key" "$value" GITHUB_OUTPUT
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { printf '%s<<%s\n' "$key" "$heredoc_delimiter"; printf '%s\n' "$value"; printf '%s\n' "$heredoc_delimiter"; } >> "$GITHUB_OUTPUT"
  else
    printf '%s<<%s\n%s\n%s\n' "$key" "$heredoc_delimiter" "$value" "$heredoc_delimiter"
  fi
}
# new_heredoc_delimiter KEY VALUE CHANNEL - set heredoc_delimiter to a fresh
# delimiter for KEY, and die when VALUE already contains it. Sets a variable
# rather than printing one: a command substitution is a subshell, and bash
# re-seeds $RANDOM there, which is the one thing a test needs to hold still.
new_heredoc_delimiter() {
  heredoc_delimiter="__workflows_eof_${RANDOM}${RANDOM}"
  case "$2" in
    *"$heredoc_delimiter"*) die "value for $1 contains the generated heredoc delimiter - refusing to write it to \$$3" ;;
  esac
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
# package_json_has SECTIONS NAME [DIRECTORY] - whether the package.json in
# DIRECTORY (default: the current one) names NAME under one of the
# comma-separated top-level SECTIONS (`scripts`, `dependencies,devDependencies`).
#
#   returns 0  it does, with a non-empty value
#   returns 1  it does not: no such entry, no such section, or no package.json
#              at all - a directory without one ships no scripts and depends on
#              nothing, which is what every caller already did with it
#   dies       package.json is there but cannot be read, is not valid JSON, or
#              is not a JSON object; the annotation names the file and the error
#
# The third outcome is the point. The probe this replaces was
# `require('./package.json')` with its stderr discarded, so a package.json that
# did not parse read as "no such script", and the gate behind it was skipped or
# swapped for a fallback instead of failing. `die` exits the calling shell, so
# call this directly (`if package_json_has ...; then`), never inside `( )` or
# `$( )`, where the die would only end the subshell and read as a 1.
#
# NAME and SECTIONS reach node through the environment, never the source text.
package_json_has() {
  local sections="$1" name="$2" directory="${3:-$PWD}" message status=0
  # shellcheck disable=SC2016 # the single quotes hold JavaScript, not shell
  message="$(PACKAGE_JSON_FILE="$directory/package.json" PACKAGE_JSON_SECTIONS="$sections" PACKAGE_JSON_NAME="$name" node -e '
    const fs = require("fs");
    const file = process.env.PACKAGE_JSON_FILE;
    const fail = (why) => { process.stdout.write(`${file} ${why}`.replace(/\s*\n\s*/g, " ")); process.exit(2); };
    let text;
    try { text = fs.readFileSync(file, "utf8"); } catch (error) {
      if (error.code === "ENOENT") process.exit(1);
      fail(`could not be read: ${error.message}`);
    }
    let pkg;
    try { pkg = JSON.parse(text); } catch (error) { fail(`is not valid JSON: ${error.message}`); }
    if (pkg === null || typeof pkg !== "object" || Array.isArray(pkg)) fail("is not a JSON object");
    const name = process.env.PACKAGE_JSON_NAME;
    const found = process.env.PACKAGE_JSON_SECTIONS.split(",").some((key) => {
      const section = Object.hasOwn(pkg, key) ? pkg[key] : undefined;
      return section !== null && typeof section === "object" && Object.hasOwn(section, name) && Boolean(section[name]);
    });
    process.exit(found ? 0 : 1);')" || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    2) die "$message - fix it: without a readable package.json there is no telling whether it names \"$name\" under $sections" ;;
    *) die "package_json_has: node exited $status reading $directory/package.json${message:+: $message}" ;;
  esac
}
require_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done; }
# gh_ref_exists REF
#
# Whether the git ref REF (`tags/v1.2.3`, `heads/main`) exists in $GH_REPO.
# True when GitHub returns it, with the commit it points at left in
# $gh_ref_sha; false only when GitHub answers 404. Every other failure - bad
# credentials, a missing scope, a rate limit, a 5xx, no network - is fatal:
# "we could not ask" must never be read as "it is not there", which once made a
# release step pass --target for a tag that already existed.
#
# `gh api` exits 1 for every HTTP error alike and prints the error body on
# stdout even under --jq, so the answer is read from its stderr, where it ends
# each one with "(HTTP <status>)". A 404 also covers a repository the token
# cannot see at all; GitHub gives no other answer for that, and the write the
# caller makes next fails on its own.
#
# Call it as a condition (`if gh_ref_exists "tags/$tag"`), never through
# $(...): the die below must end the script, not a subshell.
gh_ref_exists() {
  local ref="$1" err_file err rc=0
  : "${GH_REPO:?GH_REPO not set}"
  gh_ref_sha=""
  err_file="$(mktemp)" || die "could not create a temporary file to look up ref $ref"
  gh_ref_sha="$(gh api "repos/$GH_REPO/git/ref/$ref" --jq '.object.sha' 2>"$err_file")" || rc=$?
  err="$(cat "$err_file")"
  rm -f "$err_file"
  if [ "$rc" -eq 0 ]; then
    [ -n "$gh_ref_sha" ] || die "GitHub returned ref $ref of $GH_REPO without the commit it points at - refusing to guess"
    return 0
  fi
  gh_ref_sha=""
  case "$err" in
    *'(HTTP 404)'*) return 1 ;;
  esac
  err="${err//$'\n'/ }"
  [ -n "$err" ] || err="gh api exited $rc with no message"
  die "could not check whether ref $ref exists in $GH_REPO: $err - refusing to guess. Check that GH_TOKEN is set and may read the repository's contents; if GitHub was rate limiting or unavailable, re-run the job."
}
