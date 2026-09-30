#!/usr/bin/env bash
# Everything an iOS simulator build needs beyond Xcode itself: Xcode selected
# and past its first launch, an iOS simulator runtime, and CocoaPods in mise's
# Ruby. macOS only; a no-op elsewhere. Idempotent. Needs toolchain.sh first.
# Run from the app's root.
#
#   bash node_modules/@blinkbitcoin/app-tooling/setup/ios.sh [--boot]
#
#   --boot  also boot an iPhone simulator (the newest one), creating it if needed
#
# Installing Xcode, selecting it and accepting its licence need an admin
# password, so those are checked and the exact command printed, never run.
set -euo pipefail
# shellcheck source=scripts/setup/lib.sh
. "$(dirname "$0")/lib.sh"
parse_common_args "$@"

if [ "$(os)" != darwin ]; then
  ok "not macOS: iOS setup skipped"
  exit 0
fi
use_mise_env

step "Xcode"
developer_dir="$(xcode-select -p 2>/dev/null || true)"
case "$developer_dir" in
  *.app/Contents/Developer) ok "selected: $developer_dir" ;;
  "") die "Xcode is not installed. Install it from the App Store, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" ;;
  *) die "the Command Line Tools are selected ($developer_dir), not Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" ;;
esac
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 ||
  die "Xcode's first-launch setup has not run. Run: sudo xcodebuild -runFirstLaunch"
xcodebuild -license check >/dev/null 2>&1 ||
  die "the Xcode licence has not been accepted. Run: sudo xcodebuild -license accept"
ok "$(xcodebuild -version | head -1)"

step "iOS simulator runtime"
has_ios_runtime() {
  xcrun simctl list runtimes --json |
    node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8")).runtimes;process.exit(r.some(x=>x.platform==="iOS"&&x.isAvailable)?0:1)'
}
if has_ios_runtime; then
  ok "installed"
else
  info "downloading the iOS platform (several GB)"
  retry 3 xcodebuild -downloadPlatform iOS
  has_ios_runtime || die "no iOS simulator runtime after xcodebuild -downloadPlatform iOS"
  ok "installed"
fi

step "CocoaPods $COCOAPODS_VERSION (mise Ruby $(ruby -e 'print RUBY_VERSION'))"
# CocoaPods refuses to run under a non-UTF-8 locale.
export LANG="${LANG:-en_US.UTF-8}"
case "$LANG" in *UTF-8*) ;; *) export LANG=en_US.UTF-8 ;; esac
if gem list --installed cocoapods --version "$COCOAPODS_VERSION" >/dev/null 2>&1; then
  ok "cocoapods $COCOAPODS_VERSION"
else
  retry 3 gem install cocoapods --version "$COCOAPODS_VERSION" --no-document
  ok "cocoapods $(pod --version)"
fi

step "code signing"
# Not a setup failure, a warning worth reading: Expo signs even a *simulator*
# build when the app declares an entitlement that needs it (Associated
# Domains, App Groups, ...), and with no certificate the build stops with
# "No code signing certificates are available to use."
identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -c ')' || true)"
if [ "$identities" -gt 0 ]; then
  ok "$identities signing identities"
else
  warn "no code signing certificate on this machine. Fine for simulator builds unless the app"
  warn "declares signed entitlements (Associated Domains, App Groups): then add an Apple Development certificate."
fi

if [ "$SETUP_BOOT" = 1 ]; then
  step "boot a simulator"
  booted="$(xcrun simctl list devices booted --json | node -e '
    const d=JSON.parse(require("fs").readFileSync(0,"utf8")).devices;
    const b=Object.values(d).flat().find(x=>x.name.startsWith("iPhone"));
    if (b) console.log(b.udid)')"
  if [ -n "$booted" ]; then
    ok "already booted: $booted"
  else
    # The newest iPhone on the newest iOS runtime; created if none exists.
    # Read on a line of its own, not through `< <(...)`: set -e does not see a
    # failure there, and an empty pick would boot a simulator called "".
    pick="$(xcrun simctl list --json | node -e '
      const j=JSON.parse(require("fs").readFileSync(0,"utf8"));
      const rt=j.runtimes.filter(r=>r.platform==="iOS"&&r.isAvailable).sort((a,b)=>a.version.localeCompare(b.version,undefined,{numeric:true})).pop();
      const phones=(j.devices[rt.identifier]||[]).filter(d=>d.isAvailable&&d.name.startsWith("iPhone"));
      const types=(rt.supportedDeviceTypes||[]).filter(t=>t.identifier.startsWith(process.argv[1]));
      const phone=phones.sort((a,b)=>a.name.localeCompare(b.name,undefined,{numeric:true})).pop();
      const type=types.sort((a,b)=>a.name.localeCompare(b.name,undefined,{numeric:true})).pop();
      console.log(phone?phone.udid:"-", rt.identifier, type?type.identifier:"-")' "$IOS_SIMULATOR_DEVICE_TYPE_PREFIX")"
    read -r udid runtime device_type <<<"$pick"
    if [ "$udid" = - ]; then
      [ "$device_type" != - ] || die "no iPhone device type for $runtime"
      udid="$(xcrun simctl create "iPhone (setup)" "$device_type" "$runtime")"
      info "created $udid ($device_type)"
    fi
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" >/dev/null
    ok "booted $udid"
  fi
fi

cat <<'EOF'

iOS is ready.
EOF
