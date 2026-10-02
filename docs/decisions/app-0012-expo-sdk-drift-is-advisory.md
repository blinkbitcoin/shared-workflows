# 12. Expo SDK patch drift is a warning, not a failing check

- **Status:** Accepted
- **Date:** 2026-09-18

## Context

`expo install --check` and expo-doctor's version check demand whatever patch
the SDK expects *today*, and Expo publishes patches most weeks.
`pnpm-workspace.yaml`'s `minimumReleaseAge` refuses a package younger than a
day. For that day the two disagree: every open PR went red on a version the
repository could not install yet, and because the Checks stage gates Unit
and E2E, those were skipped behind it. Excluding the SDK from the guard was
refused earlier (a guard waived when inconvenient is not a guard); shortening
the guard to a day did not close the gap either.

## Decision

The drift is reported, never enforced. The guard alone decides when a patch
comes in.

- the shared tooling package's `checks/expo-health.sh` (a copy of the
  template's own script until shared-workflows v0.19.0 shipped it) — runs
  `expo install --check`, prints its table,
  annotates a CI warning, and lets expo-doctor decide the exit code with its
  own version check switched off (`EXPO_DOCTOR_SKIP_DEPENDENCY_VERSION_CHECK`,
  the same check having just run). Doctor's other checks still block.
- `package.json` — `check:expo-health` runs the script; `knip.json` lists
  `expo-doctor` under `ignoreDependencies`, since only that script runs it.
- `scripts/gates.test.mjs` — pins the shape.

## Consequences

A drift that outlives the guard is only a warning too; someone has to read the
annotation or run `make check-expo-health`. The bump itself stays a `chore(deps)` PR
made the day the guard opens (`pnpm exec expo install --fix`).

## Alternatives

- **Exclude the SDK from `minimumReleaseAge`** — green whatever the cooldown;
  the guard would then guard nothing that matters.
- **Keep the check blocking** — one red day per Expo patch, with Unit and E2E
  skipped on every PR for that day.
