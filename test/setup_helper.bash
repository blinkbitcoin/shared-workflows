# shellcheck shell=bash
# The sandbox the machine setup tests (scripts/setup/*.sh) run in: a throwaway
# app, HOME and TMPDIR under $BATS_TEST_TMPDIR, and every outside tool replaced
# by a fake on PATH. Nothing touches the network or the real machine. Each fake
# appends "<name> <arguments>" to $LOG, which is what most assertions read.
#
# Every fake is a symbolic link to test/fixtures/fake-tool, which does the
# logging and sources the fake's body from $FAKEBIN/<name>.impl. A fresh
# script per fake per test cost the parallel suite most of a minute on macOS,
# which checks each new executable's first run one at a time across the
# machine; never write a fake as a new executable file, link it instead.
#
# Loaded after test_helper by test/setup-lib.bats, toolchain.bats,
# setup-android.bats, setup-ios.bats and setup-all.bats.

# The body of each fake, sourced by a wrapper that logs the call first. A test
# changes a fake's behaviour by rewriting its .impl file.
write_fake_impls() {
  # uname: FAKE_OS for -s, FAKE_ARCH for -m.
  cat >"$FAKEBIN/uname.impl" <<'EOF'
if [ "$1" = -m ]; then echo "${FAKE_ARCH:-arm64}"; else echo "${FAKE_OS:-Darwin}"; fi
EOF
  # curl [-o <file>] <url>: serves the fixture named after the URL's basename,
  # to the file after -o or, without one, to stdout (curl ... | sh).
  cat >"$FAKEBIN/curl.impl" <<'EOF'
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
[ -n "${FAKE_CURL_FAIL:-}" ] && exit 22
if [ -n "$out" ]; then cp "$SETUP_FIXTURES/$(basename "$url")" "$out"; else cat "$SETUP_FIXTURES/$(basename "$url")"; fi
EOF
  # mise: like the real one, run from the app, `env` exports what .env.local holds.
  cat >"$FAKEBIN/mise.impl" <<'EOF'
case "$1" in
  --version) echo "2026.9.12 macos-arm64" ;;
  env) if [ -f .env.local ]; then sed 's/^/export /' .env.local; fi ;;
  exec) shift; [ "$1" = -- ] && shift; exec "$@" ;;
esac
true
EOF
  printf 'true\n' >"$FAKEBIN/make.impl"
  printf 'true\n' >"$FAKEBIN/brew.impl"
  printf 'true\n' >"$FAKEBIN/sleep.impl"
  printf 'exit "${FAKE_PNPM_STATUS:-0}"\n' >"$FAKEBIN/pnpm.impl"
  printf 'true\n' >"$FAKEBIN/bundle.impl"
  # The Android CLI: "sdk install --sdk=<root> <path>" creates the package the
  # way the real one does, licence file included. FAKE_INSTALL_FAILURES makes
  # the first N installs fail, to exercise the retry.
  cat >"$FAKEBIN/android.impl" <<'EOF'
for a in "$@"; do case "$a" in --sdk=*) sdk="${a#--sdk=}" ;; esac; done
pkg="${!#}"
count="$WORK/install-attempts"; n=$(cat "$count" 2>/dev/null || echo 0); echo $((n + 1)) >"$count"
[ "$n" -lt "${FAKE_INSTALL_FAILURES:-0}" ] && exit 1
mkdir -p "$sdk/$pkg" "$sdk/licenses"; touch "$sdk/$pkg/source.properties" "$sdk/licenses/android-sdk-license"
# Like the real packages, these two ship an executable the scripts call.
case "$pkg" in
  emulator) tool=emulator ;;
  platform-tools) tool=adb ;;
  *) tool= ;;
esac
[ -z "$tool" ] || ln -sf "$FAKE_TOOL" "$sdk/$pkg/$tool"
true
EOF
  # Records the AVD it creates and the answer to its custom-hardware-profile
  # prompt, as the real one reads it.
  cat >"$FAKEBIN/avdmanager.impl" <<'EOF'
prev=""
for a in "$@"; do case "$prev" in --name) echo "$a" >>"$WORK/avds" ;; esac; prev="$a"; done
read -r answer; echo "$answer" >"$WORK/avdmanager-answer"
EOF
  # exec, so a reader that stops early kills it with SIGPIPE as it would the real one.
  cat >"$FAKEBIN/emulator.impl" <<'EOF'
if [ "$1" = -list-avds ] && [ -f "$WORK/avds" ]; then exec cat "$WORK/avds"; fi
true
EOF
  cat >"$FAKEBIN/adb.impl" <<'EOF'
case "$1 ${2:-}" in
  # $WORK/adb-devices, when present, is a list too long for an environment
  # variable (Linux caps one at 128 KiB); exec, so SIGPIPE reaches the caller.
  "devices ") [ -f "$WORK/adb-devices" ] && exec cat "$WORK/adb-devices"
    printf 'List of devices attached\n%s' "${FAKE_ADB_DEVICES:-}" ;;
  "shell getprop") echo 1 ;;
esac
true
EOF
  cat >"$FAKEBIN/xcode-select.impl" <<'EOF'
echo "${FAKE_DEVELOPER_DIR-/Applications/Xcode.app/Contents/Developer}"
EOF
  cat >"$FAKEBIN/xcodebuild.impl" <<'EOF'
case "$1" in
  -checkFirstLaunchStatus) exit "${FAKE_FIRST_LAUNCH:-0}" ;;
  -license) exit "${FAKE_LICENSE:-0}" ;;
  -version) echo "Xcode 27.0" ;;
  -downloadPlatform) echo '{"runtimes":[{"platform":"iOS","isAvailable":true,"identifier":"rt.iOS-27-0","version":"27.0"}]}' >"$WORK/runtimes.json" ;;
esac
true
EOF
  cat >"$FAKEBIN/xcrun.impl" <<'EOF'
case "$2 $3" in
  "list runtimes") cat "$WORK/runtimes.json" ;;
  "list devices") cat "$WORK/booted.json" ;;
  "list --json") cat "$WORK/all.json" ;;
  "create iPhone (setup)") echo NEW-UDID ;;
esac
true
EOF
  cat >"$FAKEBIN/gem.impl" <<'EOF'
[ "$1" = list ] && exit "${FAKE_GEM_MISSING:-0}"
echo "LANG=$LANG" >>"$LOG"
EOF
  printf 'echo 1.17.0\n' >"$FAKEBIN/pod.impl"
  # shellcheck disable=SC2016  # expanded by the fake, not here
  printf 'printf "%%s" "${FAKE_IDENTITIES:-  0 valid identities found}"\n' >"$FAKEBIN/security.impl"
  printf '%s\n' "echo 'openjdk version \"17.0.20\"' >&2" >"$FAKEBIN/java.impl"
  printf 'printf 3.3.12\n' >"$FAKEBIN/ruby.impl"
  printf 'echo 2026.9.21\n' >"$FAKEBIN/watchman.impl"
}

# The names of every fake put on PATH.
FAKE_TOOLS="uname curl mise make brew sleep pnpm bundle android avdmanager emulator adb xcode-select xcodebuild xcrun gem pod security java ruby watchman"

# fake_wrapper NAME DIRECTORY: the fake NAME in DIRECTORY, a link to the one
# logging dispatcher (test/fixtures/fake-tool), which sources NAME's body.
fake_wrapper() { ln -sf "$FAKE_TOOL" "$2/$1"; }

# setup_sandbox: the app (the working directory, holding .mise.toml and React
# Native's catalogue), HOME, TMPDIR, fixtures and fakes. Sets APP, SDK, WORK,
# FAKEBIN, LOG and SETUP_FIXTURES.
setup_sandbox() {
  WORK="$BATS_TEST_TMPDIR"
  FAKEBIN="$WORK/bin"
  SETUP_FIXTURES="$WORK/fixtures"
  LOG="$WORK/log"
  # Set again after the unset of FAKE_* settings below, which would clear one
  # the environment brought in.
  FAKE_TOOL="$REPO_ROOT/test/fixtures/fake-tool"
  PYTHON3="$(command -v python3)"
  local node
  node="$(node -p process.execPath)"
  mkdir -p "$WORK/app" "$WORK/home" "$WORK/tmp" "$FAKEBIN" "$WORK/nodebin" "$SETUP_FIXTURES"
  ln -sf "$node" "$WORK/nodebin/node"
  : >"$LOG"
  write_fake_impls
  local tool
  for tool in $FAKE_TOOLS; do fake_wrapper "$tool" "$FAKEBIN"; done
  printf '{"runtimes":[{"platform":"iOS","isAvailable":true}]}' >"$WORK/runtimes.json"
  printf '{"devices":{}}' >"$WORK/booted.json"
  : >"$WORK/app/.mise.toml"
  catalog 36 36.0.0 27.1.12297006

  # Whatever the runner or the developer's shell set must not steer a script.
  unset SETUP_YES SETUP_BOOT SETUP_BOOT_TIMEOUT SETUP_DOCTOR SETUP_ROOT ANDROID_HOME ANDROID_SDK_ROOT \
    CI MAESTRO_DIR MAESTRO_VERSION MAESTRO_SHA256 GITHUB_PATH
  # shellcheck disable=SC2046  # one name per word
  unset $(compgen -e | grep '^FAKE_' || true)
  export HOME="$WORK/home" TMPDIR="$WORK/tmp" LOG WORK FAKEBIN SETUP_FIXTURES SETUP_RETRY_DELAY=0 \
    FAKE_TOOL="$REPO_ROOT/test/fixtures/fake-tool"
  export PATH="$FAKEBIN:$WORK/nodebin:/usr/bin:/bin:/usr/sbin:/sbin"
  cd "$WORK/app" || return 1
  APP="$(pwd -P)"
  SDK="$HOME/Library/Android/sdk"
}

# catalog COMPILE_SDK BUILD_TOOLS NDK: React Native's version catalogue in the
# app's node_modules, with those three pins (an empty one is left out).
catalog() {
  local toml="$WORK/app/node_modules/react-native/gradle/libs.versions.toml"
  mkdir -p "$(dirname "$toml")"
  {
    printf '[versions]\n'
    [ -z "$1" ] || printf 'compileSdk = "%s"\n' "$1"
    [ -z "$2" ] || printf 'buildTools = "%s"\n' "$2"
    [ -z "$3" ] || printf 'ndkVersion = "%s"\n' "$3"
  } >"$toml"
}

# calls PREFIX: the logged calls of one fake, one per line.
calls() { grep "^$1 " "$LOG" || true; }

# calls_once_logged PREFIX PATTERN: the calls of PREFIX matching PATTERN, once
# one has reached the log. A fake the script starts with `nohup ... &` can log
# after the script has exited, so this polls for up to five seconds.
calls_once_logged() {
  local found
  for _ in $(seq 1 250); do
    found="$(calls "$1" | grep -E "$2" || true)"
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
      return 0
    fi
    /bin/sleep 0.02
  done
  return 1
}

# installs: the SDK paths the Android CLI was asked to install, in order.
installs() { calls android | awk '{print $NF}'; }

# make_zip NAME RELATIVE_PATH=BODY...: a zip in the fixtures of the given
# files, each executable. Prints its path.
make_zip() {
  local name="$1" staging entry
  shift
  staging="$WORK/staging-$name"
  rm -rf "$staging"
  for entry in "$@"; do
    mkdir -p "$staging/$(dirname "${entry%%=*}")"
    printf '%s\n' "${entry#*=}" >"$staging/${entry%%=*}"
    chmod +x "$staging/${entry%%=*}"
  done
  (cd "$staging" && zip -qr "$SETUP_FIXTURES/$name.zip" .)
  printf '%s\n' "$SETUP_FIXTURES/$name.zip"
}

# The Android command-line tools archive: its android and avdmanager are the
# fakes, logging and sourcing their bodies from $FAKEBIN.
cmdline_tools_zip() {
  # shellcheck disable=SC2016  # expanded by the fake, not here
  make_zip tools \
    'cmdline-tools/bin/android=#!/bin/bash
echo "android $*" >>"$LOG"
. "$FAKEBIN/android.impl"' \
    'cmdline-tools/bin/avdmanager=#!/bin/bash
echo "avdmanager $*" >>"$LOG"
. "$FAKEBIN/avdmanager.impl"'
}

# plant_cmdline_tools SDK: the command-line tools already in SDK, so nothing
# is downloaded.
plant_cmdline_tools() {
  mkdir -p "$1/cmdline-tools/latest/bin"
  fake_wrapper android "$1/cmdline-tools/latest/bin"
  fake_wrapper avdmanager "$1/cmdline-tools/latest/bin"
}

# plant_maestro VERSION: a Maestro in ~/.maestro that reports VERSION.
plant_maestro() {
  mkdir -p "$HOME/.maestro/bin"
  printf '#!/bin/bash\necho %s\n' "$1" >"$HOME/.maestro/bin/maestro"
  chmod +x "$HOME/.maestro/bin/maestro"
}

# tooling_copy LAYOUT: a copy of scripts/setup, scripts/lib and scripts/ci laid
# out as this repository has them (`repository`: <root>/scripts/{setup,lib,ci})
# or as the package ships them (`package`: <root>/{setup,lib,ci}). Sets TOOLING
# to the root and COPY_SETUP to the copy's setup/ directory, so a test can
# change a pin in "$TOOLING_LIB/versions.sh" without touching the real one.
tooling_copy() {
  local base
  if [ "$1" = package ]; then
    TOOLING="$WORK/pkg"
    base="$TOOLING"
  else
    TOOLING="$WORK/ws"
    base="$TOOLING/scripts"
  fi
  mkdir -p "$base"
  cp -R "$REPO_ROOT/scripts/setup" "$REPO_ROOT/scripts/lib" "$REPO_ROOT/scripts/ci" "$base/"
  COPY_SETUP="$base/setup"
  TOOLING_LIB="$base/lib"
}

# set_pin NAME VALUE: rewrites one pin in the copy's versions.sh.
set_pin() {
  sed -i.bak "s|^export $1=.*|export $1=\"$2\"|" "$TOOLING_LIB/versions.sh"
}

sha_of() { shasum -a "$1" "$2" | cut -d' ' -f1; }

# The consent prompt on a real pseudo-terminal (Python's pty module, the same
# on macOS and Linux): the answer is typed once the question appears.
PTY_DRIVER='
import os, pty, sys
answer = sys.argv[1].encode() + b"\n"
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash"] + sys.argv[2:])
out, sent = b"", False
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if not sent and b"[y/N]" in out:
        os.write(fd, answer)
        sent = True
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitpid(pid, 0)[1] >> 8)
'

# in_terminal ANSWER ARGUMENTS...: runs `bash ARGUMENTS...` on a terminal and
# answers the [y/N] question with ANSWER; sets status and output like `run`.
in_terminal() {
  local answer="$1"
  shift
  run "$PYTHON3" -c "$PTY_DRIVER" "$answer" "$@"
}
