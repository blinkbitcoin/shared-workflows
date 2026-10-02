# 9. E2E launches the dev client by deep link, never from its launcher

- **Status:** Accepted for Android; superseded for iOS by [0010](app-0010-ios-e2e-release-build.md). Since 2026-10-01 a local run launches with the shared tooling's `app-launch.sh`, the script CI runs, through `scripts/e2e/maestro.sh`; `maestro-ios.sh` and `maestro-android.sh` are gone and the decision stands.
- **Date:** 2026-09-06

## Context

The template ships `expo-dev-client`, so an E2E run starts on the dev client's
launcher screen, whose "DEVELOPMENT SERVERS" list is populated by Bonjour
discovery — and **Bonjour does not work on a simulator or an emulator**, in CI
or locally, so the list stays empty and a flow waiting to tap it hangs.

## Decision

The runner, not the flow, foregrounds the app, by opening the
`expo-development-client` deep link with the Metro URL. Flows attach to the
running app and never restart it.

- `scripts/e2e/maestro-ios.sh` — `xcrun simctl openurl booted
  "$SCHEME://expo-development-client/?url=http%3A%2F%2Flocalhost%3A8081"`,
  then `maestro test .maestro`; `maestro-android.sh` is the `adb` equivalent,
  and CI does the same once per run via `$WORKFLOWS_DIR/scripts/e2e/app-launch.sh`.
- `.maestro/flows/00-launch.yaml` — `launchApp: stopApp: false`, no
  `clearState`, `extendedWaitUntil` on `home-screen` (Maestro 2.x has no
  `timeout` on `assertVisible`); its launcher and LogBox taps are optional.

## Consequences

Any flow adding `clearState` or `stopApp: true` drops the dev client back on
its launcher and strands every flow after it; the rule is written into
`00-launch.yaml` where the next author will read it. Flows are one ordered
suite, not independent cases: state is reset in-app, later flows assume Home,
and Metro plus the mock API must be up (`scripts/e2e/wait-for-mock-api.sh`).

## Alternatives

- **Tap through the launcher** — rejected: Bonjour never populates it here.
- **A release build with an embedded bundle** — an option later: it drops Metro
  but loses fast iteration and dev-only screens.
- **Relaunch per flow for isolation** — rejected: it lands on the launcher.
