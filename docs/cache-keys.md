# Cache keys

Every cache this family writes, what produces the key, and what invalidates it.
Bumping the `native-cache-version` input (default `v1`) invalidates every
native cache at once — including the Android system-image and AVD caches, which
used to bake `v1` in as a literal and so survived every bump, quietly outliving
the stale-AVD failures people bumped it to clear.

## The native dependency hash

`hash` is a 16-hex digest computed by `scripts/ci/native-hash.sh` (wrapped by
`scripts/ci/native-keys.sh`, exposed by the `native-key` composite action). It
is deliberately computable *before* `pnpm install`, so a cache lookup never
waits on a dependency install. It folds together:

1. From `pnpm-lock.yaml`, `importers["."]`: every runtime dependency, plus the
   devDependencies whose name matches
   `^(expo|@expo/|react-native|@react-native|@react-native-community|@config-plugins/|patch-package)`,
   rendered as `name@version` (read with `yq`).
2. A `shasum -a 256` per file (not `hashFiles`) over two sets: the
   **root-level only** (`find -maxdepth 1`) matches of `app.config.*`,
   `app.json`, `Gemfile.lock`, `.mise.toml`, `google-services.json`,
   `GoogleService-Info.plist`; and every file found **recursively** under
   `plugins/`, `modules/` and `patches/`. A nested `app.config.ts` is
   deliberately not picked up — if you have one, add it via
   `native-extra-globs`.
3. The contents of every file matched by the `native-extra-globs` input
   (`check-e2e.yml` input of the same name, threaded into the `native-key` action) —
   space-separated, consumer-relative shell globs, e.g.
   `fastlane/*.rb android/keystores/*`. No recursive `**` (these scripts run
   under macOS's bash 3.2, which has no `globstar`). The glob *string* itself is
   folded in too, so changing the patterns also invalidates the caches.

## Keys

| Cache | Key | Produced by | Used in |
| --- | --- | --- | --- |
| iOS app (`.app` + `ios/*.xcworkspace`) | `ios-app-{ver}-{os}-{arch}-xcode{x}-{hash}[-env{8hex}]-{configuration}` (exact; `{x}` is the `xcode` input or `default`; `-env{8hex}` is a digest of `build-env` and is absent when that input is empty, because the `.app` embeds `EXPO_PUBLIC_*` at bundle time; `check-e2e.yml` appends `ios-configuration`) | `native-key` action → `scripts/ci/native-keys.sh` (`ios-key` output) | `check-e2e.yml` job `build-ios`, `actions/cache/restore@v6` + `actions/cache/save@v6` |
| Android debug APK | `android-apk-{ver}-{hash}` (exact) | `native-key` action → `scripts/ci/native-keys.sh` (`android-key` output) | `check-e2e.yml` job `build-android`, restore + save |
| CocoaPods (`ios/Pods`, `~/Library/Caches/CocoaPods`) | `pods-{os}-{hash}`, restore-keys prefix `pods-{os}-` | `native-key` action → `scripts/ci/native-keys.sh` (`pods-key` output) | `check-e2e.yml` job `build-ios` and `build-ios.yml` job `build`, `actions/cache@v6` (a prefix hit is fine: `pod install` reconciles) |
| pnpm store | `pnpm-{os}-{hashFiles('**/pnpm-lock.yaml')}`, restore-keys prefix `pnpm-{os}-` | `setup` action (path from `scripts/ci/pnpm-store-path.sh`) | every workflow that runs `setup` |
| Maestro CLI (`~/.maestro`, excluding `tests/` and `logs/`) | `maestro-{os}-{version}-v2` | `maestro` action (version = its `version` input, pinned to `MAESTRO_VERSION`) | `check-e2e.yml` jobs `ios`, `android` |
| Android system image | `sysimg-{ver}-{api}-default-x86_64` | `check-e2e.yml` job `android` (`{api}` = `android-api-level`) | `actions/cache@v6` over `$ANDROID_SDK_DIR/system-images/android-{api}` |
| AVD + adb keys | `avd-{ver}-{api}-x86_64-default-hidedialogs` | `check-e2e.yml` job `android` | `actions/cache@v6` over `~/.android/avd/*`, `~/.android/adb*`; a miss bakes a snapshot via `scripts/e2e/android-emulator.sh snapshot-bake` |
| Playwright browsers | `playwright-{os}-{pwversion}` | `build-web.yml` job `playwright` (version from `scripts/web/playwright-cache-key.sh`, which wraps `scripts/web/playwright-version.sh`) | `build-web.yml` playwright job |
| Gradle | managed by `gradle/actions/setup-gradle` | that action | `check-e2e.yml` job `build-android` and `build-android.yml`; only the `default-branch` ref writes it, every other ref reads it |
| mise tools | managed by `jdx/mise-action` (`cache: true`) | that action | `setup` and `native-key` actions |

Notes:

- The `-hidedialogs` suffix on the AVD key is a content marker, not a value read
  from anywhere: the cached snapshot has `hide_error_dialogs 1` and
  `anr_show_background 0` baked in. Change what `snapshot-bake` writes and bump
  the suffix.
- The Maestro cache excludes `~/.maestro/tests` and `~/.maestro/logs`: both are
  per-run CLI output, so a cache that carries them grows run over run and every
  later job restores a blob it never reads. The `-v2` suffix is what makes the
  exclusion take effect on an existing repo — `actions/cache` only *saves* on a
  key miss, so a warm key would keep restoring the fat entry forever. Bump it
  again with any future change to what this cache holds.
- `{ver}` is the `native-cache-version` input, `{os}`/`{arch}` come from the
  runner, and `{hash}` is the native dependency hash above. The system-image and
  AVD keys used to bake `v1` in as a literal while this page and three input
  descriptions all promised the bump reached every native cache; they did not,
  so a stale AVD outlived the bump meant to clear it. `test/workflow-shape.bats`
  now refuses any workflow cache key with a version baked in.
- The Maestro CLI key's `-v2` is deliberately **not** `{ver}`: that cache holds
  the CLI, not build output, and nothing about a native rebuild invalidates it.
  It lives in a composite action rather than a workflow, which is also why the
  bats rule above does not reach it.
- The iOS app cache carries the generated `ios/*.xcworkspace` alongside the
  built `.app` because `scripts/native/ios-pack.sh` resolves the Xcode scheme
  from the workspace, and on a cache hit no `expo prebuild` has run.
