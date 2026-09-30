# @blinkbitcoin/expo-tooling

The Expo and React Native counterpart of
[`@blinkbitcoin/dev-config`](../dev-config): the home of the configuration
every app of this family runs — Jest, ESLint, Biome, Metro, Playwright,
lefthook, fingerprint, TypeScript and commitlint — as presets an app extends,
so the app's own files keep only what is genuinely its own. The presets land
in the change after this one; this one wires the package into the repository.

It comes in the way dev-config does, as a git dependency at the commit the
workflows are pinned to:

```json
"@blinkbitcoin/expo-tooling": "github:blinkbitcoin/shared-workflows#<sha>&path:/packages/expo-tooling"
```

`fix-tooling-pin` and `check-lockfile` from dev-config already handle it, like
any other `packages/<name>` of this repository.

## Tests

`make test-package` at the repository root runs every package's suite at 100%
lines, branches and functions.
