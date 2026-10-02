# 7. `mise` pins the toolchain, not Nix

- **Status:** Accepted. The doctor and `make setup` are the shared tooling's since 2026-10-01 (`pnpm exec doctor`, `setup/` in `@blinkbitcoin/app-tooling`); the decision stands.
- **Date:** 2026-09-05

## Context

A React Native build touches Node, pnpm, Java, Ruby and a handful of linters,
and "works on my machine" is usually a version skew in one of them. The options
are a hermetic environment (Nix) or a version manager that pins tools but uses
the machine's Xcode and Android SDK. Nix buys reproducibility at the price of
an onboarding cliff, friction with Xcode, and a language to learn first.

## Decision

`mise` is the single version pin for humans and CI, with a `doctor` script for
what mise cannot install.

- `.mise.toml` — node 24, pnpm 12, java temurin-17, ruby 3.3, plus
  `actionlint`, `shellcheck`, `typos`; `EXPO_NO_TELEMETRY=1`, `_.path` for
  `node_modules/.bin` and `_.file` for a gitignored `.env.local`.
- CI reads this same file through `jdx/mise-action` in the workflows repo's
  `.github/actions/setup/action.yml`, reached by the reusable workflows the
  template's `.github/workflows/*.yml` call, so local and CI pin alike.
- `scripts/doctor.mjs` + `doctor.requirements.json` (`make doctor`) — checks
  Xcode, watchman, the Android SDK and the mise tools against minimum versions
  and prints the fix for each miss.

## Consequences

Onboarding is `mise trust && mise install && make doctor`, and the pin cannot
drift between laptop and CI. The environment is not hermetic: Xcode, the
Android SDK and CocoaPods come from the machine, so `make doctor` records the
minimums. mise builds Ruby from source on macOS; CI uses `ruby/setup-ruby`.

## Alternatives

- **Nix or devenv** — rejected: onboarding cost and Xcode friction outweigh the
  reproducibility for a store app. Revisited 2026-09-15 against the sibling
  `esign` repo's `flake.nix` + `.envrc`, and the answer did not change. Nix's
  hermetic closure stops at Xcode and the Android SDK, which are what actually
  decide whether an Expo build works on macOS, so the closure would cover the
  easy half of the problem and leave `make doctor` in place for the hard half.
  Every tool the flake provides is in mise's registry except watchman, an
  optional Metro accelerator Homebrew installs.
- **direnv** — rejected: `mise activate` already does the directory-switching
  that direnv exists for, and the rest of what `esign`'s `.envrc` does is
  covered by `[env]` keys in `.mise.toml` — `_.path = ["node_modules/.bin"]`
  puts locally installed CLIs on PATH, and `_.file = [".env.local"]` loads
  gitignored per-machine overrides. Adding direnv would be a second mechanism
  for a job already done, with a second file to keep in sync.
- **asdf** — rejected: mise is a drop-in with a maintained GitHub Action.
- **Docker for local dev** — rejected: iOS builds cannot run in it.
