import { createJestConfig } from '@blinkbitcoin/app-tooling/expo/jest';

// Everything generic - the two projects, the ignored directories, the transforms,
// the console guard, the Expo stand-ins and the 100% thresholds - is the
// preset's. This file holds this app's paths.
export default createJestConfig({
  setupFiles: ['<rootDir>/src/test/env.ts'],
  setupFilesAfterEnv: ['<rootDir>/src/test/setup.ts'],
  moduleNameMapper: { '^@/(.*)$': '<rootDir>/src/$1' },
  // Each entry is a claim that the file has no behaviour a test could assert.
  coveragePathIgnorePatterns: [
    // Jest setup files run before instrumentation, so they report 0%.
    '<rootDir>/src/test/(env|setup)\\.ts$',
    // Generated: GraphQL codegen output and the compiled Lingui catalogs.
    '<rootDir>/src/graphql/generated/',
    '<rootDir>/src/i18n/locales/',
    // Zero-statement route re-exports, each pinned by its own test.
    '<rootDir>/src/app/\\(tabs\\)/(index|settings)\\.tsx$',
    '<rootDir>/src/app/\\+native-intent\\.tsx$',
    // The requireNativeModule bindings; modules/*/index.ts is the tested wrapper.
    '<rootDir>/modules/[^/]+/src/',
  ],
});
