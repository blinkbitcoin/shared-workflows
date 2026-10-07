#!/usr/bin/env bats
load test_helper

# scripts/ci/maestro-install.sh: install Maestro from its release archive,
# checked against the pinned SHA-256, or keep an install already at the pin.
#
# Two regressions pinned here:
# - maestro prints a first-run analytics notice before its version, so
#   comparing the whole `--version` output against the pin failed on every
#   fresh runner ("expected 2.10.0, got Anonymous analytics enabled...").
# - the install ran `bash -c "$(curl get.maestro.mobile.dev)"`: a script
#   fetched fresh each time, and an archive nothing checked.

setup() {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  export PATH="$fakebin:/usr/bin:/bin"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.maestro/bin"
  MAESTRO_PIN="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; echo "$MAESTRO_VERSION"')"
  unset MAESTRO_VERSION MAESTRO_SHA256 GITHUB_PATH
  CURL_CALLS="$BATS_TEST_TMPDIR/curl-calls"
  : > "$CURL_CALLS"
  # curl must never reach the network: by default it fails, and a case that
  # needs a download points it at a local file with serve_file.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$CURL_CALLS" > "$fakebin/curl"
  chmod +x "$fakebin/curl"
}

# Plants an installed maestro whose --version prints $1.
plant_maestro() {
  printf '#!/usr/bin/env bash\ncat <<%s\n%s\n%s\n' 'EOF' "$1" 'EOF' > "$HOME/.maestro/bin/maestro"
  chmod +x "$HOME/.maestro/bin/maestro"
}

# make_archive VERSION [nolib] - builds maestro.zip in the test dir, holding a
# maestro/bin/maestro that prints VERSION and a maestro/lib (left out with
# `nolib`), and prints the archive's SHA-256.
make_archive() {
  local src="$BATS_TEST_TMPDIR/src"
  rm -rf "$src" "$BATS_TEST_TMPDIR/maestro.zip"
  mkdir -p "$src/maestro/bin"
  if [ "${2:-}" != nolib ]; then
    mkdir -p "$src/maestro/lib"
    printf 'jar\n' > "$src/maestro/lib/maestro.jar"
  fi
  printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$src/maestro/bin/maestro"
  chmod +x "$src/maestro/bin/maestro"
  (cd "$src" && zip -qr "$BATS_TEST_TMPDIR/maestro.zip" maestro)
  shasum -a 256 "$BATS_TEST_TMPDIR/maestro.zip" | cut -d' ' -f1
}

# serve_file FILE - a curl that records its arguments and "downloads" FILE to
# the path after -o.
serve_file() {
  cat > "$fakebin/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CURL_CALLS"
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = -o ]; then cp "$1" "\$2"; exit 0; fi
  shift
done
exit 1
STUB
  chmod +x "$fakebin/curl"
}

install() { run bash "$REPO_ROOT/scripts/ci/maestro-install.sh"; }

@test "an install already at the pin is kept, and nothing is downloaded" {
  plant_maestro "$MAESTRO_PIN"
  install
  [ "$status" -eq 0 ] || fail "expected success, got $status: $output"
  [ ! -s "$CURL_CALLS" ] || fail "downloaded anyway: $(cat "$CURL_CALLS")"
}

@test "the analytics notice before the version does not break the check" {
  plant_maestro "Anonymous analytics enabled. To opt out, set MAESTRO_CLI_NO_ANALYTICS environment variable to any value before running Maestro.
$MAESTRO_PIN"
  install
  [ "$status" -eq 0 ] || fail "the banner should not be read as the version: $output"
}

@test "a verified archive replaces a wrong version and lands on PATH" {
  plant_maestro "2.9.0"
  sha="$(make_archive "$MAESTRO_PIN")"
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github_path"
  MAESTRO_SHA256="$sha" install
  [ "$status" -eq 0 ] || fail "expected success, got $status: $output"
  [ "$("$HOME/.maestro/bin/maestro" --version)" = "$MAESTRO_PIN" ] || fail "the archive was not installed"
  [ -f "$HOME/.maestro/lib/maestro.jar" ] || fail "maestro/lib was not installed"
  traced "$output" "Download and install Maestro $MAESTRO_PIN" || fail "the install was not timed: $output"
  [ "$(cat "$GITHUB_PATH")" = "$HOME/.maestro/bin" ] || fail "not put on PATH: $(cat "$GITHUB_PATH")"
  contains "$(cat "$CURL_CALLS")" "releases/download/cli-$MAESTRO_PIN/maestro.zip" \
    || fail "not the release archive: $(cat "$CURL_CALLS")"
}

@test "with no checksum given, the pinned version is held to the pinned checksum" {
  plant_maestro "2.9.0"
  make_archive "$MAESTRO_PIN" >/dev/null
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  install
  [ "$status" -ne 0 ] || fail "installed bytes that do not match the pinned checksum: $output"
  contains "$output" "refusing an unverified Maestro download" || fail "unexpected message: $output"
}

@test "an archive that does not match its checksum is refused, and the old install is left alone" {
  plant_maestro "2.9.0"
  make_archive "$MAESTRO_PIN" >/dev/null
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  MAESTRO_SHA256="0000000000000000000000000000000000000000000000000000000000000000" install
  [ "$status" -ne 0 ] || fail "installed unverified bytes: $output"
  contains "$output" "refusing an unverified Maestro download" || fail "unexpected message: $output"
  [ "$("$HOME/.maestro/bin/maestro")" = "2.9.0" ] || fail "the old install was touched before verification"
}

@test "a failed download names the version and the URL" {
  plant_maestro "2.9.0"
  install
  [ "$status" -ne 0 ] || fail "expected failure: $output"
  contains "$output" "could not download Maestro $MAESTRO_PIN" || fail "unexpected message: $output"
}

@test "an archive that is not a zip is refused" {
  plant_maestro "2.9.0"
  printf 'not a zip\n' > "$BATS_TEST_TMPDIR/broken.zip"
  serve_file "$BATS_TEST_TMPDIR/broken.zip"
  MAESTRO_SHA256="$(shasum -a 256 "$BATS_TEST_TMPDIR/broken.zip" | cut -d' ' -f1)" install
  [ "$status" -ne 0 ] || fail "expected failure: $output"
  contains "$output" "did not unzip" || fail "unexpected message: $output"
}

@test "an archive without maestro/bin and maestro/lib is refused" {
  plant_maestro "2.9.0"
  sha="$(make_archive "$MAESTRO_PIN" nolib)"
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  MAESTRO_SHA256="$sha" install
  [ "$status" -ne 0 ] || fail "expected failure: $output"
  contains "$output" "holds no maestro/bin and maestro/lib" || fail "unexpected message: $output"
}

@test "an archive that installs the wrong version reports the mismatch" {
  plant_maestro "2.9.0"
  sha="$(make_archive "2.9.1")"
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  MAESTRO_SHA256="$sha" install
  [ "$status" -ne 0 ] || fail "expected failure: $output"
  contains "$output" "version mismatch" || fail "expected a version mismatch message: $output"
}

@test "a version other than the pin needs its own checksum, and downloads nothing without one" {
  plant_maestro "2.9.0"
  MAESTRO_VERSION="9.9.9" install
  [ "$status" -ne 0 ] || fail "installed an unpinned version with no checksum: $output"
  contains "$output" "is not the pinned $MAESTRO_PIN" || fail "unexpected message: $output"
  contains "$output" "maestro-sha256" || fail "does not say which input to set: $output"
  [ ! -s "$CURL_CALLS" ] || fail "downloaded anyway: $(cat "$CURL_CALLS")"
}

@test "a version other than the pin installs with its own checksum" {
  plant_maestro "2.9.0"
  sha="$(make_archive "9.9.9")"
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  MAESTRO_VERSION="9.9.9" MAESTRO_SHA256="$sha" install
  [ "$status" -eq 0 ] || fail "expected success, got $status: $output"
  contains "$(cat "$CURL_CALLS")" "releases/download/cli-9.9.9/maestro.zip" || fail "wrong URL: $(cat "$CURL_CALLS")"
}

@test "no maestro at all installs one" {
  rm -rf "$HOME/.maestro"
  sha="$(make_archive "$MAESTRO_PIN")"
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  MAESTRO_SHA256="$sha" install
  [ "$status" -eq 0 ] || fail "expected success, got $status: $output"
  [ -x "$HOME/.maestro/bin/maestro" ] || fail "nothing was installed"
}

@test "analytics are turned off rather than merely parsed around" {
  grep -q 'MAESTRO_CLI_NO_ANALYTICS=1' "$REPO_ROOT/scripts/ci/maestro-install.sh" ||
    fail "the script should opt out of telemetry, not just tolerate the notice"
}

@test "the install never runs a script fetched from the network" {
  # Code lines only: the header explains why the installer is not used.
  code="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/scripts/ci/maestro-install.sh")"
  not_contains "$code" "get.maestro.mobile.dev" || fail "the curl|bash installer is back"
}

@test "the pinned checksum is a SHA-256" {
  sha="$(bash -c 'source "$REPO_ROOT/scripts/lib/versions.sh"; echo "$MAESTRO_SHA256"')"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "MAESTRO_SHA256 is not a SHA-256: '$sha'"
}

@test "MAESTRO_DIR installs somewhere other than ~/.maestro, and GITHUB_PATH gets that bin" {
  local dir="$BATS_TEST_TMPDIR/tools/maestro"
  sha="$(make_archive "$MAESTRO_PIN")"
  serve_file "$BATS_TEST_TMPDIR/maestro.zip"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github-path"
  MAESTRO_DIR="$dir" MAESTRO_SHA256="$sha" install
  [ "$status" -eq 0 ] || fail "expected success, got $status: $output"
  [ -x "$dir/bin/maestro" ] || fail "nothing was installed in MAESTRO_DIR"
  [ ! -e "$HOME/.maestro/bin/maestro" ] || fail "it installed into ~/.maestro as well"
  [ "$(cat "$GITHUB_PATH")" = "$dir/bin" ] || fail "GITHUB_PATH: $(cat "$GITHUB_PATH")"
  : > "$CURL_CALLS"
  MAESTRO_DIR="$dir" install
  [ "$status" -eq 0 ] || fail "the install in MAESTRO_DIR was not kept: $output"
  [ ! -s "$CURL_CALLS" ] || fail "downloaded again: $(cat "$CURL_CALLS")"
}

@test "the package's copy installs from where a consumer has it, with its libraries beside it" {
  plant_maestro "$MAESTRO_PIN"
  run bash "$REPO_ROOT/packages/app-tooling/ci/maestro-install.sh"
  [ "$status" -eq 0 ] || fail "the packaged copy did not run: $output"
}
