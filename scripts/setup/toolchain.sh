#!/usr/bin/env bash
# The shared toolchain every platform needs: mise and the versions the app's
# .mise.toml pins (node, pnpm, java, ruby and the linters), watchman on macOS,
# then the app's own dependencies. Run from the app's root. Idempotent.
#
#   bash node_modules/@blinkbitcoin/app-tooling/setup/toolchain.sh [--yes]
set -euo pipefail
# shellcheck source=scripts/setup/lib.sh
. "$(dirname "$0")/lib.sh"
parse_common_args "$@"

# Everything below reads the app's .mise.toml; without one this is not an
# app's root, and mise would quietly install nothing.
[ -f "$SETUP_ROOT/.mise.toml" ] ||
  die "no .mise.toml in $SETUP_ROOT. Run this from the app's root."

step "mise"
if ! have mise; then
  if [ "$(os)" = darwin ] && have brew; then
    info "installing mise with Homebrew"
    retry 3 brew install mise
  else
    # The official installer is a remote script, so it is asked about first.
    consent "Download and run the mise installer from https://mise.run"
    retry 3 bash -c 'curl -fsSL https://mise.run | sh'
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
have mise || die "mise is not on PATH after installing it. Add ~/.local/bin to PATH and re-run."
ok "mise $(mise --version 2>/dev/null | cut -d' ' -f1)"

# An untrusted .mise.toml is silently ignored for tools and env alike: java
# then resolves to macOS's /usr/bin/java stub ("Unable to locate a Java
# Runtime") and ruby to whatever else is on PATH.
mise trust --quiet "$SETUP_ROOT/.mise.toml"
ok "trusted $SETUP_ROOT/.mise.toml"

step "pinned tools (node, pnpm, java, ruby, linters)"
retry 3 mise install --yes
# From here on this script, and anything it runs, sees mise's versions.
eval "$(cd "$SETUP_ROOT" && mise env --shell bash)"
ok "java $(java -version 2>&1 | head -1 | cut -d'"' -f2), ruby $(ruby -e 'print RUBY_VERSION'), node $(node --version)"

if [ "$(os)" = darwin ]; then
  step "watchman"
  if have watchman; then
    ok "watchman $(watchman --version)"
  else
    have brew || die "watchman needs Homebrew (https://brew.sh), which is not installed"
    retry 3 brew install watchman
    ok "watchman $(watchman --version)"
  fi
fi

# After mise, never before: gems installed under another Ruby land in
# vendor/bundle/ruby/<that version> and `bundle check` then fails.
# The app's own `make install` when it has one, since that is where an app adds
# its git hooks and anything else; otherwise the two installs every app needs.
if [ -f "$SETUP_ROOT/Makefile" ] && grep -qE '^install[[:space:]]*:([^=]|$)' "$SETUP_ROOT/Makefile"; then
  step "project dependencies (make install)"
  retry 3 make -C "$SETUP_ROOT" install
  ok "make install finished"
else
  step "project dependencies (pnpm install)"
  retry 3 pnpm install --frozen-lockfile
  ok "pnpm packages installed"
  if [ -f "$SETUP_ROOT/Gemfile" ]; then
    retry 3 bundle install
    ok "Ruby gems installed"
  fi
fi
