# Fixture apps for the fingerprint suite

`base/` is an Expo app in the template's shape that the suite passes.
Each directory under `cases/` is laid over a copy of `base/`, and its
`case.json` says whether the suite passes there and what its output must
say. `modules/` is installed as the app's `node_modules` unless a case sets
`"modules": false`.

`modules/@expo/fingerprint` is a stand-in for the library, small enough to
read: it hashes `app.config.js` for one platform, drops the version fields
when `sourceSkips` holds `ExpoConfigVersions`, and, like the real one, falls
back to its defaults when `fingerprint.config.js` throws.
