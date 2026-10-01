#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/bare/app-config.sh, the bare stack's identifiers, read out of
# the committed native projects. xcodebuild is a fake that records its
# arguments and prints $XCODEBUILD_JSON, or fails like a workspace without Pods
# when that is unset. Covered, per key: the explicit input winning, each source
# in its order of preference, every fallback, every refusal with its fix; the
# debug build type's applicationIdSuffix in Groovy and Kotlin, present and
# absent, and the release variant without it; and an unknown key, a missing
# working directory and the bare fixture.
load test_helper

setup() {
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP"
  export GITHUB_WORKSPACE="$APP" WORKING_DIRECTORY=.
  unset IOS_BUNDLE_ID IOS_SCHEME ANDROID_PACKAGE WORKFLOWS_IOS_CONFIGURATION WORKFLOWS_ANDROID_VARIANT XCODEBUILD_JSON
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  cat > "$bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf 'xcodebuild %s\n' "$*" >> "$CALLS"
[ -n "${XCODEBUILD_JSON:-}" ] || exit 65
printf '%s' "$XCODEBUILD_JSON"
STUB
  chmod +x "$bin/xcodebuild"
  export PATH="$bin:$PATH"
}

config() { run bash "$REPO_ROOT/scripts/native/bare/app-config.sh" "$@"; }

# Prints a PATH directory with the tools the script uses, the fake xcodebuild
# unless "no-xcodebuild" is given, and node unless "no-node" is.
curated_path() {
  local dir="$BATS_TEST_TMPDIR/curated" tool
  rm -rf "$dir"
  mkdir -p "$dir"
  for tool in bash dirname find sort grep sed awk head basename env paste tr cat wc node; do
    case " $* " in *" no-$tool "*) continue ;; esac
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  case " $* " in *" no-xcodebuild "*) ;; *) ln -sf "$bin/xcodebuild" "$dir/xcodebuild" ;; esac
  printf '%s\n' "$dir"
}

workspace() { mkdir -p "$APP/ios/$1.xcworkspace"; }

# pbxproj LINE... - a project file holding the given build-setting lines.
pbxproj() {
  mkdir -p "$APP/ios/App.xcodeproj"
  printf '%s\n' "$@" > "$APP/ios/App.xcodeproj/project.pbxproj"
}

# --- ios-scheme ----------------------------------------------------------------

@test "ios-scheme: the explicit input wins over the workspace" {
  workspace App
  IOS_SCHEME=Other config ios-scheme
  [ "$output" = Other ] || fail "$status: $output"
}

@test "ios-scheme: the single workspace's name" {
  workspace Terminal
  config ios-scheme
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = Terminal ] || fail "got: $output"
}

@test "ios-scheme: no workspace fails with the fix" {
  config ios-scheme
  [ "$status" -eq 1 ] || fail "answered without a workspace: $output"
  contains "$output" "no ios/*.xcworkspace in $(cd "$APP" && pwd -P)" || fail "output: $output"
  contains "$output" "or pass the ios-scheme input" || fail "no fix: $output"
}

@test "ios-scheme: two workspaces are ambiguous, and both are named" {
  workspace One
  workspace Two
  config ios-scheme
  [ "$status" -eq 1 ] || fail "picked one of two: $output"
  contains "$output" "2 workspaces in" || fail "output: $output"
  contains "$output" "ios/One.xcworkspace ios/Two.xcworkspace" || fail "output: $output"
}

# --- ios-bundle-id ---------------------------------------------------------------

@test "ios-bundle-id: the explicit input wins, and xcodebuild is not asked" {
  workspace App
  IOS_BUNDLE_ID=com.example.input config ios-bundle-id
  [ "$output" = com.example.input ] || fail "$status: $output"
  [ ! -s "$CALLS" ] || fail "xcodebuild ran anyway: $(cat "$CALLS")"
}

@test "ios-bundle-id: xcodebuild's application target, on the workspace, scheme and configuration" {
  workspace App
  export XCODEBUILD_JSON='[{"target":"AppTests","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"com.example.tests","WRAPPER_EXTENSION":"xctest"}},{"target":"App","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"com.example.app.dev","WRAPPER_EXTENSION":"app"}}]'
  WORKFLOWS_IOS_CONFIGURATION=Release config ios-bundle-id
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = com.example.app.dev ] || fail "got: $output"
  [ "$(cat "$CALLS")" = "xcodebuild -showBuildSettings -json -workspace ios/App.xcworkspace -scheme App -configuration Release" ] \
    || fail "asked: $(cat "$CALLS")"
}

@test "ios-bundle-id: with no application target in the JSON, the first identifier; Debug by default" {
  workspace App
  export XCODEBUILD_JSON='[{"buildSettings":{}},{"buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"com.example.first"}}]'
  config ios-bundle-id
  [ "$output" = com.example.first ] || fail "$status: $output"
  contains "$(cat "$CALLS")" "-configuration Debug" || fail "asked: $(cat "$CALLS")"
}

@test "ios-bundle-id: xcodebuild failing, or answering nonsense, falls back to the project file" {
  workspace App
  pbxproj '				PRODUCT_BUNDLE_IDENTIFIER = com.example.pbx;'
  config ios-bundle-id
  [ "$output" = com.example.pbx ] || fail "after a failing xcodebuild: $status $output"
  for json in 'not json' '{"an":"object"}' '[]'; do
    XCODEBUILD_JSON="$json" config ios-bundle-id
    [ "$output" = com.example.pbx ] || fail "after '$json': $status $output"
  done
}

@test "ios-bundle-id: without xcodebuild, without node or without a single workspace, the project file is read" {
  pbxproj '				PRODUCT_BUNDLE_IDENTIFIER = com.example.pbx;'
  config ios-bundle-id
  [ "$output" = com.example.pbx ] || fail "no workspace: $status $output"
  [ ! -s "$CALLS" ] || fail "xcodebuild ran without a workspace: $(cat "$CALLS")"
  workspace App
  export XCODEBUILD_JSON='[{"buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"com.example.xcode"}}]'
  PATH="$(curated_path no-xcodebuild)" config ios-bundle-id
  [ "$output" = com.example.pbx ] || fail "no xcodebuild: $status $output"
  PATH="$(curated_path no-node)" config ios-bundle-id
  [ "$output" = com.example.pbx ] || fail "no node: $status $output"
}

@test "ios-bundle-id: the project file's quoted values are read, references and test targets skipped" {
  pbxproj '				PRODUCT_BUNDLE_IDENTIFIER = "$(PRODUCT_NAME:rfc1034identifier)";' \
    '				PRODUCT_BUNDLE_IDENTIFIER = "com.example.appTests";' \
    '				PRODUCT_BUNDLE_IDENTIFIER = "com.example.quoted";' \
    '				PRODUCT_BUNDLE_IDENTIFIER = com.example.quoted;'
  config ios-bundle-id
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = com.example.quoted ] || fail "got: $output"
}

@test "ios-bundle-id: several identifiers in the project warn and take the first" {
  pbxproj '				PRODUCT_BUNDLE_IDENTIFIER = com.example.debug;' '				PRODUCT_BUNDLE_IDENTIFIER = com.example.release;'
  config ios-bundle-id
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "::warning::2 bundle identifiers in the project (com.example.debug com.example.release); using the first" || fail "output: $output"
  [ "$(printf '%s\n' "$output" | tail -1)" = com.example.debug ] || fail "output: $output"
}

@test "ios-bundle-id: nothing to read fails with the fix" {
  pbxproj '				PRODUCT_BUNDLE_IDENTIFIER = "$(BUNDLE_ID)";'
  config ios-bundle-id
  [ "$status" -eq 1 ] || fail "answered: $output"
  contains "$output" "no bundle identifier in $(cd "$APP" && pwd -P)/ios" || fail "output: $output"
  contains "$output" "or pass the ios-bundle-id input" || fail "no fix: $output"
  rm -rf "$APP/ios"
  config ios-bundle-id
  [ "$status" -eq 1 ] || fail "answered with no ios/: $output"
}

# --- android-package -------------------------------------------------------------

@test "android-package: the explicit input wins" {
  ANDROID_PACKAGE=com.example.input config android-package
  [ "$output" = com.example.input ] || fail "$status: $output"
}

@test "android-package: applicationId in either quote style, or the Kotlin assignment" {
  mkdir -p "$APP/android/app"
  printf 'android {\n  defaultConfig {\n    applicationId "com.example.groovy"\n  }\n}\n' > "$APP/android/app/build.gradle"
  config android-package
  [ "$output" = com.example.groovy ] || fail "double quotes: $status $output"
  printf "    applicationId 'com.example.single'\n" > "$APP/android/app/build.gradle"
  config android-package
  [ "$output" = com.example.single ] || fail "single quotes: $status $output"
  # A build.gradle without one does not stop the .kts from being read.
  printf 'android {}\n' > "$APP/android/app/build.gradle"
  printf '    applicationId = "com.example.kotlin"\n' > "$APP/android/app/build.gradle.kts"
  config android-package
  [ "$output" = com.example.kotlin ] || fail "Kotlin: $status $output"
}

# gradle FILE TEXT - android/app/FILE holding TEXT.
gradle() {
  mkdir -p "$APP/android/app"
  printf '%s' "$2" > "$APP/android/app/$1"
}

GROOVY_SUFFIX='android {
    defaultConfig {
        applicationId "com.example.app"
    }
    signingConfigs {
        debug {
            storeFile file("debug.keystore")
        }
    }
    buildTypes {
        release {
            applicationIdSuffix ".release"
        }
        debug {
            // applicationIdSuffix ".commented"
            signingConfig signingConfigs.debug
            applicationIdSuffix ".debug"
        }
    }
}
'

KOTLIN_SUFFIX='android {
    defaultConfig {
        applicationId = "com.example.app"
    }
    buildTypes {
        getByName("release") {
            applicationIdSuffix = ".release"
        }
        getByName("debug") {
            applicationIdSuffix = ".dev"
        }
    }
}
'

@test "android-package: the debug build type's applicationIdSuffix is appended, in Groovy" {
  gradle build.gradle "$GROOVY_SUFFIX"
  config android-package
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = com.example.app.debug ] || fail "got: $output"
}

@test "android-package: the debug build type's applicationIdSuffix is appended, in Kotlin" {
  gradle build.gradle.kts "$KOTLIN_SUFFIX"
  config android-package
  [ "$output" = com.example.app.dev ] || fail "getByName: $status $output"
  # named("debug") and the plain accessor, on one line, single quotes.
  gradle build.gradle.kts "$(printf 'android {\n  defaultConfig {\n    applicationId = "com.example.app"\n  }\n  buildTypes {\n    named("debug") {\n      applicationIdSuffix = ".named"\n    }\n  }\n}\n')"
  config android-package
  [ "$output" = com.example.app.named ] || fail "named: $status $output"
  gradle build.gradle.kts "$(printf "android {\n  applicationId = 'com.example.app'\n  buildTypes { debug { applicationIdSuffix = '.one' } }\n}\n")"
  config android-package
  [ "$output" = com.example.app.one ] || fail "one line: $status $output"
}

@test "android-package: without a debug suffix the applicationId is answered alone" {
  # A release suffix and a debug block without one (and after it closes, a
  # suffix outside any debug block) are not the debug build type's.
  gradle build.gradle "$(printf 'android {\n  defaultConfig {\n    applicationId "com.example.app"\n  }\n  buildTypes {\n    debug {\n      signingConfig signingConfigs.debug\n    }\n    release {\n      applicationIdSuffix ".release"\n    }\n  }\n}\n')"
  config android-package
  [ "$output" = com.example.app ] || fail "Groovy: $status $output"
  rm "$APP/android/app/build.gradle"
  gradle build.gradle.kts "$(printf 'android {\n  defaultConfig {\n    applicationId = "com.example.app"\n  }\n}\n')"
  config android-package
  [ "$output" = com.example.app ] || fail "Kotlin: $status $output"
}

@test "android-package: the release variant is the bare applicationId, suffix or not" {
  gradle build.gradle "$GROOVY_SUFFIX"
  WORKFLOWS_ANDROID_VARIANT=release config android-package
  [ "$output" = com.example.app ] || fail "Groovy: $status $output"
  rm "$APP/android/app/build.gradle"
  gradle build.gradle.kts "$KOTLIN_SUFFIX"
  WORKFLOWS_ANDROID_VARIANT=release config android-package
  [ "$output" = com.example.app ] || fail "Kotlin: $status $output"
  WORKFLOWS_ANDROID_VARIANT=debug config android-package
  [ "$output" = com.example.app.dev ] || fail "an explicit debug: $status $output"
}

@test "android-package: the explicit input is answered as given, with no suffix added" {
  gradle build.gradle "$GROOVY_SUFFIX"
  ANDROID_PACKAGE=com.example.input config android-package
  [ "$output" = com.example.input ] || fail "$status: $output"
}

@test "android-package: a variant other than debug or release fails, naming it" {
  gradle build.gradle "$GROOVY_SUFFIX"
  WORKFLOWS_ANDROID_VARIANT=staging config android-package
  [ "$status" -eq 1 ] || fail "answered: $output"
  contains "$output" "WORKFLOWS_ANDROID_VARIANT must be debug or release (got 'staging')" || fail "output: $output"
}

@test "android-package: no literal applicationId fails with the fix" {
  mkdir -p "$APP/android/app"
  printf '    applicationId rootProject.ext.appId\n' > "$APP/android/app/build.gradle"
  config android-package
  [ "$status" -eq 1 ] || fail "answered: $output"
  contains "$output" "no literal applicationId in" || fail "output: $output"
  contains "$output" "or pass the android-package input" || fail "no fix: $output"
}

# --- scheme ----------------------------------------------------------------------

plist_with_schemes() {
  mkdir -p "$(dirname "$1")"
  {
    printf '<plist><dict>\n<key>CFBundleURLTypes</key>\n<array><dict>\n<key>CFBundleURLSchemes</key>\n<array>\n'
    shift
    for scheme in "$@"; do printf '\t<string>%s</string>\n' "$scheme"; done
    printf '</array>\n</dict></array>\n<key>Other</key>\n<string>not-a-scheme</string>\n</dict></plist>\n'
  } > "$1"
}

@test "scheme: the first literal CFBundleURLSchemes entry of the workspace's app" {
  workspace Terminal
  plist_with_schemes "$APP/ios/Terminal/Info.plist" '$(PRODUCT_BUNDLE_IDENTIFIER)' terminal second
  plist_with_schemes "$APP/ios/Another/Info.plist" another
  config scheme
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = terminal ] || fail "got: $output"
}

@test "scheme: without a workspace's Info.plist, the first non-test target's" {
  plist_with_schemes "$APP/ios/AppTests/Info.plist" tests
  plist_with_schemes "$APP/ios/Main/Info.plist" main
  config scheme
  [ "$output" = main ] || fail "$status: $output"
}

@test "scheme: an Info.plist without URL schemes falls through to the manifest's first non-web scheme" {
  mkdir -p "$APP/ios/App" "$APP/android/app/src/main"
  printf '<plist><dict><key>CFBundleName</key><string>App</string></dict></plist>\n' > "$APP/ios/App/Info.plist"
  printf '<manifest>\n<data android:scheme="https" android:host="example.com"/>\n<data android:scheme="terminal"/>\n</manifest>\n' \
    > "$APP/android/app/src/main/AndroidManifest.xml"
  config scheme
  [ "$output" = terminal ] || fail "$status: $output"
}

@test "scheme: an app that declares none answers empty, successfully" {
  mkdir -p "$APP/android/app/src/main"
  printf '<manifest><data android:scheme="http"/></manifest>\n' > "$APP/android/app/src/main/AndroidManifest.xml"
  config scheme
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "invented a scheme: $output"
  rm -rf "$APP/android"
  config scheme
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "with nothing at all: $status $output"
}

# --- the rest --------------------------------------------------------------------

@test "an unknown key fails naming the four" {
  config bundle
  [ "$status" -ne 0 ] || fail "answered an unknown key: $output"
  contains "$output" "unknown app-config key 'bundle' (one of: ios-bundle-id, android-package, scheme, ios-scheme)" || fail "output: $output"
}

@test "a working directory that does not exist fails" {
  WORKING_DIRECTORY=missing config ios-scheme
  [ "$status" -ne 0 ] || fail "answered: $output"
  contains "$output" "the consumer's working directory does not exist" || fail "output: $output"
}

@test "the bare fixture answers every key from its committed projects" {
  export GITHUB_WORKSPACE="$FIXTURES/consumer-bare"
  config ios-bundle-id
  [ "$output" = com.example.bare ] || fail "ios-bundle-id: $status $output"
  config android-package
  [ "$output" = com.example.bare ] || fail "android-package: $status $output"
  config ios-scheme
  [ "$output" = App ] || fail "ios-scheme: $status $output"
  config scheme
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "scheme: $status $output"
}
