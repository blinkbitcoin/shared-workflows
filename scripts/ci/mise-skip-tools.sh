#!/usr/bin/env bash
# Leave the tools a job does not use out of mise, before the `setup` action
# installs the consumer's .mise.toml.
#
# Every job used to install the whole file, Java and Ruby included, where most
# run only node and pnpm: a download on every mise cache miss (a Ruby compile on
# macOS) and a larger cache to restore on every hit. And wherever Ruby is
# enabled, ruby/setup-ruby installs it again and its copy is the one on PATH, so
# mise's was installed for nothing.
#
# Inputs, as environment variables:
#   SKIP_TOOLS    space-separated tool names, as .mise.toml's [tools] keys them
#   RUBY_ENABLED  'true' when the job installs Ruby through ruby/setup-ruby,
#                 which adds ruby to the list
#
# Publishes MISE_DISABLE_TOOLS for every later step in the job, mise-action's
# included, so a later `mise x` or `mise env` leaves them out too; and the step
# output `cache-key-suffix`, because mise-action's default cache key does not
# read that variable, and a narrowed job would otherwise share its cache entry
# with a full one. Nothing skipped publishes no variable and an empty suffix,
# which leaves the key exactly as it was.
#
# The tools stay in .mise.toml: ruby-version.sh reads Ruby's version from it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

names="${SKIP_TOOLS:-}"
if [ "${RUBY_ENABLED:-false}" = "true" ]; then names="$names ruby"; fi

# `read -a`, not an unquoted `for name in $names`: that would expand a `*` in
# the input against the working directory's files.
read -r -a tools <<< "$names" || true
# `${tools[@]+...}`: bash 3.2 calls an empty array unbound under `set -u`.
for name in ${tools[@]+"${tools[@]}"}; do
  # `die`, not `die_fix`: skip-tools is this repository's own input, never a
  # consumer's, so the fix is here and the consumer guide has nothing to say.
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || die "skip-tools names \"$name\", which is not a tool name as .mise.toml's [tools] keys one (java, ruby), space-separated"
done

# One name per line, sorted and without repeats, so the same set always makes
# the same cache key whatever order a caller wrote it in.
sorted=""
if [ "${#tools[@]}" -gt 0 ]; then
  sorted="$(printf '%s\n' "${tools[@]}" | env LC_ALL=C sort -u)"
fi
if [ -z "$sorted" ]; then
  gh_output cache-key-suffix ""
  exit 0
fi

disabled="$(printf '%s' "$sorted" | tr '\n' ',')"
suffix="-without-$(printf '%s' "$sorted" | tr '\n' '-')"
log "mise skips: $disabled"
gh_env MISE_DISABLE_TOOLS "$disabled"
gh_output cache-key-suffix "$suffix"
