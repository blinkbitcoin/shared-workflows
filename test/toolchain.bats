#!/usr/bin/env bats
# scripts/setup/toolchain.sh - mise and the versions the app's .mise.toml
# pins, watchman on macOS, then the app's own dependencies, all in the app the
# working directory holds. Run against fakes of mise, brew, curl, make, pnpm
# and bundle on PATH, in a throwaway app and HOME (test/setup_helper.bash).
#
# Covers every way out: no .mise.toml; mise present, installed by Homebrew on a
# Mac, or by the remote installer (refused without a yes, run with one, and one
# that leaves no mise behind), including a Mac without Homebrew; watchman
# present, installed by Homebrew, impossible without Homebrew, and skipped on
# Linux; and the install step - the app's `make install` when its Makefile has
# that target, otherwise `pnpm install --frozen-lockfile` plus `bundle install`
# when there is a Gemfile - and an install that keeps failing. Also: the order
# (mise before any dependency) and an unknown flag.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper
load setup_helper

setup() {
  setup_sandbox
  SCRIPT="$REPO_ROOT/scripts/setup/toolchain.sh"
}

# toolchain ARGUMENTS...: runs the script with no terminal to answer consent.
toolchain() { run bash "$SCRIPT" "$@" </dev/null; }

# Takes mise off PATH, keeping it as $FAKEBIN/mise.real for an installer to put back.
remove_mise() {
  mv "$FAKEBIN/mise" "$FAKEBIN/mise.real"
}

@test "mise is trusted and installed before any dependency, never after" {
  printf 'install:\n\tpnpm install\n' >"$APP/Makefile"
  toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local order
  order="$(grep -E '^(mise (trust|install)|make |pnpm )' "$LOG")"
  [ "$order" = "mise trust --quiet $APP/.mise.toml
mise install --yes
make -C $APP install" ] || fail "order: $order"
}

@test "an app whose Makefile has an install target gets its own make install, and nothing else" {
  printf '.PHONY: install\ninstall: ## Install everything\n\tpnpm install\n' >"$APP/Makefile"
  : >"$APP/Gemfile"
  toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(calls make)" = "make -C $APP install" ] || fail "make: $(calls make)"
  [ -z "$(calls pnpm)$(calls bundle)" ] || fail "installed besides make install: $(calls pnpm) $(calls bundle)"
  contains "$output" "project dependencies (make install)" || fail "step: $output"
}

@test "a Makefile without an install target means pnpm install, and no bundle without a Gemfile" {
  printf 'install_dir := /opt\ninstaller:\n\ttrue\n' >"$APP/Makefile"
  toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$(calls make)" ] || fail "make was called: $(calls make)"
  [ "$(calls pnpm)" = "pnpm install --frozen-lockfile" ] || fail "pnpm: $(calls pnpm)"
  [ -z "$(calls bundle)" ] || fail "bundle without a Gemfile: $(calls bundle)"
  contains "$output" "pnpm packages installed" || fail "output: $output"
}

@test "no Makefile and a Gemfile means pnpm install, then bundle install, in the app" {
  : >"$APP/Gemfile"
  cat >"$FAKEBIN/bundle.impl" <<'EOF'
echo "bundle ran in $(pwd -P)" >>"$LOG"
EOF
  toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(grep -E '^(pnpm|bundle) ' "$LOG")" = "pnpm install --frozen-lockfile
bundle install
bundle ran in $APP" ] || fail "installs: $(grep -E '^(pnpm|bundle) ' "$LOG")"
  contains "$output" "Ruby gems installed" || fail "output: $output"
}

@test "an install that keeps failing is retried, then stops the run" {
  FAKE_PNPM_STATUS=1 toolchain
  [ "$status" -ne 0 ] || fail "succeeded: $output"
  contains "$output" "gave up after 3 attempts: pnpm install --frozen-lockfile" || fail "output: $output"
  [ "$(calls pnpm | wc -l | tr -d ' ')" = 3 ] || fail "attempts: $(calls pnpm)"
}

@test "without a .mise.toml it is not run from an app's root, and says so" {
  rm "$APP/.mise.toml"
  toolchain
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "no .mise.toml in $APP. Run this from the app's root." || fail "output: $output"
  [ -z "$(calls mise)" ] || fail "mise was called: $(calls mise)"
}

@test "on a Mac without mise, Homebrew installs it" {
  remove_mise
  printf 'cp "$FAKEBIN/mise.real" "$FAKEBIN/mise"\n' >"$FAKEBIN/brew.impl"
  toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(calls brew)" "brew install mise" || fail "brew: $(calls brew)"
  [ -z "$(calls curl)" ] || fail "the remote installer ran: $(calls curl)"
}

@test "on Linux, the remote mise installer needs a yes" {
  remove_mise
  FAKE_OS=Linux toolchain
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "not confirmed: Download and run the mise installer" || fail "output: $output"
  [ -z "$(calls curl)" ] || fail "downloaded anyway: $(calls curl)"
}

@test "on a Mac without Homebrew, the remote mise installer is asked about too" {
  remove_mise
  rm "$FAKEBIN/brew"
  toolchain
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "not confirmed: Download and run the mise installer" || fail "output: $output"
}

@test "with a yes, the mise installer runs and its ~/.local/bin is used" {
  remove_mise
  # What https://mise.run does: drop mise into ~/.local/bin.
  printf 'mkdir -p "$HOME/.local/bin" && cp "$FAKEBIN/mise.real" "$HOME/.local/bin/mise"\n' >"$SETUP_FIXTURES/mise.run"
  FAKE_OS=Linux toolchain --yes
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -x "$HOME/.local/bin/mise" ] || fail "mise not installed into ~/.local/bin"
  [ "$(calls curl)" = "curl -fsSL https://mise.run" ] || fail "curl: $(calls curl)"
  contains "$output" "ok    mise 2026.9.12" || fail "the installed mise was not used: $output"
}

@test "an installer that leaves no mise behind is reported, not ignored" {
  remove_mise
  printf 'true\n' >"$SETUP_FIXTURES/mise.run"
  FAKE_OS=Linux toolchain --yes
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "mise is not on PATH after installing it" || fail "output: $output"
}

@test "a Mac with watchman keeps it" {
  toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "ok    watchman 2026.9.21" || fail "output: $output"
  [ -z "$(calls brew)" ] || fail "brew was called: $(calls brew)"
}

@test "a Mac without watchman gets it from Homebrew" {
  mv "$FAKEBIN/watchman" "$FAKEBIN/watchman.real"
  printf 'cp "$FAKEBIN/watchman.real" "$FAKEBIN/watchman"\n' >"$FAKEBIN/brew.impl"
  toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(calls brew)" "brew install watchman" || fail "brew: $(calls brew)"
  contains "$output" "ok    watchman 2026.9.21" || fail "output: $output"
}

@test "without watchman or Homebrew it says where to get Homebrew" {
  rm "$FAKEBIN/watchman" "$FAKEBIN/brew"
  toolchain
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "watchman needs Homebrew (https://brew.sh)" || fail "output: $output"
}

@test "Linux needs no watchman" {
  rm "$FAKEBIN/watchman"
  FAKE_OS=Linux toolchain
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  not_contains "$output" "watchman" || fail "output: $output"
}

@test "an unknown flag is refused" {
  toolchain --yess
  [ "$status" -eq 1 ] || fail "exited $status: $output"
  contains "$output" "unknown argument: --yess" || fail "output: $output"
}
