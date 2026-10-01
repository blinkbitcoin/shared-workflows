// The app suites test-app runs: shared tests that read an app's own files and
// run this family's code against them. check-contract asks whether what the
// workflows need is there; a suite asks whether it works.
//
// A suite is a node:test file beside this one, read from APP_ROOT. Its file is
// `<name>.suite.mjs`, not `.test.mjs`: the package's own test run takes every
// `*.test.mjs`, and a suite run there would have no app. Each is proved able
// to fail by the fixture apps under fixtures/apps/<name>/ (suites.test.mjs).
//
// `stacks` is the native stacks it applies to; `needs` the files, relative to
// the app root, without which it has nothing to test. A suite that does not
// apply is skipped, and the reason is printed.
export const SUITES = {
  fingerprint: {
    file: 'fingerprint.suite.mjs',
    stacks: ['expo'],
    needs: ['fingerprint.config.js'],
  },
};
