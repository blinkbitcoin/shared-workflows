#!/usr/bin/env bats
load test_helper

# smoke-android-sdk.sh runs inside a JDK container in real use; here it runs on
# the host against fakes of curl, sha1sum, jar and java that record their
# calls, and a fake sdkmanager that the fake jar "unpacks".

SCRIPT="$REPO_ROOT/scripts/self/smoke-android-sdk.sh"

setup() {
  export ANDROID_HOME="$BATS_TEST_TMPDIR/sdk"
  bin="$BATS_TEST_TMPDIR/bin"
  calls="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$bin"
  : > "$calls"
  # curl writes a zip unless FAKE_CURL_FAIL is set.
  cat > "$bin/curl" <<STUB
#!/usr/bin/env bash
echo "curl \$*" >> "$calls"
[ -z "\${FAKE_CURL_FAIL:-}" ] || exit 22
while [ "\$#" -gt 0 ]; do [ "\$1" = -o ] && { echo zip > "\$2"; break; }; shift; done
STUB
  # sha1sum -c passes unless FAKE_SHA_BAD is set; it must be handed the pin.
  cat > "$bin/sha1sum" <<STUB
#!/usr/bin/env bash
line="\$(cat)"
echo "sha1sum \$line" >> "$calls"
[ -z "\${FAKE_SHA_BAD:-}" ]
STUB
  # jar xf lays out cmdline-tools/bin/sdkmanager without its exec bit, as a
  # real jar does; FAKE_JAR_FAIL makes it fail.
  cat > "$bin/jar" <<STUB
#!/usr/bin/env bash
echo "jar \$*" >> "$calls"
[ -z "\${FAKE_JAR_FAIL:-}" ] || exit 1
mkdir -p cmdline-tools/bin
cp "$BATS_TEST_TMPDIR/sdkmanager" cmdline-tools/bin/sdkmanager
chmod -x cmdline-tools/bin/sdkmanager
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/java"
  # sdkmanager: --licenses reads its answers and writes the licence file
  # (FAKE_LICENSES=fail fails, =none writes nothing); --install creates the
  # package's source.properties, failing the first FAKE_INSTALL_FAILS calls
  # (FAKE_INSTALL_EMPTY=1 "succeeds" without installing anything).
  cat > "$BATS_TEST_TMPDIR/sdkmanager" <<STUB
#!/usr/bin/env bash
echo "sdkmanager \$*" >> "$calls"
root=""
for a in "\$@"; do case "\$a" in --sdk_root=*) root="\${a#--sdk_root=}" ;; esac; done
case "\$*" in
  *--licenses*)
    head -c 2 >/dev/null
    case "\${FAKE_LICENSES:-}" in fail) exit 1 ;; none) exit 0 ;; esac
    mkdir -p "\$root/licenses"; echo hash > "\$root/licenses/android-sdk-license" ;;
  *--install*)
    count_file="$BATS_TEST_TMPDIR/install-count"
    n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$count_file"
    [ "\$n" -gt "\${FAKE_INSTALL_FAILS:-0}" ] || exit 1
    [ -z "\${FAKE_INSTALL_EMPTY:-}" ] || exit 0
    pkg="\${*: -1}"; dir="\$root/\${pkg//;//}"; mkdir -p "\$dir"; touch "\$dir/source.properties" ;;
esac
STUB
  chmod +x "$bin"/* "$BATS_TEST_TMPDIR/sdkmanager"
  export PATH="$bin:$PATH"
}

@test "refuses to run without ANDROID_HOME" {
  ANDROID_HOME="" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "ANDROID_HOME is not set" || fail "output: $output"
}

@test "installs the pinned, verified tools, accepts the licences and installs every package" {
  source "$REPO_ROOT/scripts/lib/versions.sh"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  grep -q "curl .*commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip" "$calls" || fail "the pinned build was not downloaded: $(cat "$calls")"
  grep -q "sha1sum $ANDROID_CMDLINE_TOOLS_SHA1_LINUX " "$calls" || fail "the download was not checked against the pin: $(cat "$calls")"
  [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ] || fail "sdkmanager is not in place and executable"
  [ -f "$ANDROID_HOME/licenses/android-sdk-license" ] || fail "no licence was recorded"
  for package in platform-tools $ANDROID_AGP_DEFAULT_PACKAGES; do
    [ -f "$ANDROID_HOME/$package/source.properties" ] || fail "$package was not installed"
    grep -q -- "--install ${package//\//;}$" "$calls" || fail "$package was not asked for by its sdkmanager name: $(cat "$calls")"
  done
  contains "$output" "ready in $ANDROID_HOME" || fail "output: $output"
}

@test "a second run downloads nothing and installs nothing again" {
  bash "$SCRIPT" 2>/dev/null
  : > "$calls"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  ! grep -q '^curl' "$calls" || fail "the tools were downloaded again"
  ! grep -q -- '--install' "$calls" || fail "a package was installed again: $(cat "$calls")"
  contains "$output" "command-line tools already in" || fail "output: $output"
  contains "$output" "platform-tools already installed" || fail "output: $output"
}

@test "a failed download stops it" {
  FAKE_CURL_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "could not download commandlinetools-linux-" || fail "output: $output"
}

@test "a download that does not match the pinned SHA-1 is refused and never installed" {
  FAKE_SHA_BAD=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "refusing an unverified" || fail "output: $output"
  [ ! -e "$ANDROID_HOME/cmdline-tools/latest" ] || fail "the unverified tools were installed"
}

@test "a zip that will not unpack stops it" {
  FAKE_JAR_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "could not unpack" || fail "output: $output"
}

@test "a failed licence acceptance stops it, and so does one that records nothing" {
  FAKE_LICENSES=fail run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "sdkmanager --licenses failed (status 1)" || fail "output: $output"
  FAKE_LICENSES=none run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "accepted no licence" || fail "output: $output"
}

@test "a package that fails twice is retried, and one that fails three times stops it" {
  FAKE_INSTALL_FAILS=2 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "two failures were not retried: $output"
  rm -rf "$ANDROID_HOME" "$BATS_TEST_TMPDIR/install-count"
  FAKE_INSTALL_FAILS=3 run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "could not install platform-tools after 3 attempts" || fail "output: $output"
}

@test "an install that reports success but leaves nothing stops it" {
  FAKE_INSTALL_EMPTY=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "platform-tools did not install" || fail "output: $output"
}
