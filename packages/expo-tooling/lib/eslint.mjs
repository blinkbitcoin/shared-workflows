// The ESLint flat configuration for an Expo app of this family. ESLint owns
// ONLY React and Expo semantic rules (react-hooks, including the React
// Compiler rules, and Expo's environment-variable rules); Biome owns
// formatting, import order and generic lint. Nothing is enabled in both, so
// every preset rule that Biome's `recommended` set (or its react and test
// domains) already enforces is switched off here.
//
// eslint, eslint-config-expo and globals are peer dependencies: the app
// installs them, and this module takes the ones the app has.
import { defineConfig, globalIgnores } from 'eslint/config';
import expoConfig from 'eslint-config-expo/flat.js';
import globals from 'globals';

/** Paths no ESLint run reads: build output, other checkouts, fixtures. */
export const IGNORES = [
  'ios/**',
  'android/**',
  '.expo/**',
  'dist/**',
  'coverage/**',
  'vendor/bundle/**', // Ruby gems installed by `bundle install` (fastlane, cocoapods)
  '.workflows/**', // shared-workflows, checked out by CI into the workspace
  '.claude/worktrees/**', // other checkouts of this repository
  'rules/**', // Semgrep fixtures: deliberately vulnerable code, scanned by semgrep --test, not ESLint
];

/**
 * The preset rules Biome already owns. react-hooks/* is deliberately NOT
 * listed: Biome's useExhaustiveDependencies and useHookAtTopLevel are off in
 * the Biome base instead, so ESLint keeps owning the hooks rules (including
 * the React Compiler ones, which have no Biome equivalent).
 */
export const BIOME_OWNED_RULES = {
  // Stylistic or ordering rules from the preset.
  'import/order': 'off',
  'import/first': 'off',
  'import/no-duplicates': 'off',
  'prettier/prettier': 'off',

  // Generic correctness and suspicious rules that overlap one to one.
  eqeqeq: 'off', // Biome suspicious/noDoubleEquals
  'no-dupe-args': 'off', // Biome suspicious/noDuplicateParameters
  'no-dupe-class-members': 'off', // Biome suspicious/noDuplicateClassMembers
  'no-dupe-keys': 'off', // Biome suspicious/noDuplicateObjectKeys
  'no-duplicate-case': 'off', // Biome suspicious/noDuplicateCase
  'no-empty-pattern': 'off', // Biome correctness/noEmptyPattern
  'no-redeclare': 'off', // Biome suspicious/noRedeclare
  'no-unreachable': 'off', // Biome correctness/noUnreachable
  'no-unsafe-negation': 'off', // Biome suspicious/noUnsafeNegation
  'no-unused-labels': 'off', // Biome correctness/noUnusedLabels
  'no-unused-vars': 'off', // Biome correctness/noUnusedVariables
  'no-with': 'off', // Biome suspicious/noWith
  'use-isnan': 'off', // Biome correctness/useIsNan
  'valid-typeof': 'off', // Biome correctness/useValidTypeof
  '@typescript-eslint/no-dupe-class-members': 'off', // Biome suspicious/noDuplicateClassMembers
  '@typescript-eslint/no-redeclare': 'off', // Biome suspicious/noRedeclare
  '@typescript-eslint/no-unused-vars': 'off', // Biome correctness/noUnusedVariables
  '@typescript-eslint/no-useless-constructor': 'off', // Biome complexity/noUselessConstructor
  '@typescript-eslint/no-extra-non-null-assertion': 'off', // Biome suspicious/noExtraNonNullAssertion
  '@typescript-eslint/no-empty-object-type': 'off', // Biome complexity/noBannedTypes
  '@typescript-eslint/no-wrapper-object-types': 'off', // Biome complexity/noBannedTypes
  'react/jsx-key': 'off', // Biome correctness/useJsxKeyInIterable (react domain)
  'react/jsx-no-comment-textnodes': 'off', // Biome suspicious/noCommentText
  'react/jsx-no-duplicate-props': 'off', // Biome suspicious/noDuplicateJsxProps
  'react/no-children-prop': 'off', // Biome correctness/noChildrenProp (react domain)
  'react/no-danger-with-children': 'off', // Biome security/noDangerouslySetInnerHtmlWithChildren (react domain)
  'react/no-render-return-value': 'off', // Biome correctness/noRenderReturnValue (react domain)
  // react/no-unknown-property (the JSX unknown-attribute check, class versus
  // className) stays ON: Biome's correctness/noUnknownProperty validates CSS
  // property names only and cannot fire on JSX, so there is no overlap.
};

/** Files that run in Node rather than in the app, and so see Node's globals. */
export const NODE_FILES = ['babel.config.js', 'metro.config.js', 'scripts/**/*.mjs'];

/**
 * The effective flat configuration, already passed through `defineConfig`.
 *
 * @param {object} [options]
 * @param {string[]} [options.ignores] appended to the generic ignores (generated code, say)
 * @param {string[]} [options.nodeFiles] appended to the files that get Node's globals
 */
export function createEslintConfig({ ignores = [], nodeFiles = [] } = {}) {
  return defineConfig([
    globalIgnores([...IGNORES, ...ignores], 'expo-tooling/ignores'),
    // eslint-config-expo's flat export is an array today; one object would do too.
    ...[expoConfig].flat(),
    { name: 'expo-tooling/biome-owned', rules: BIOME_OWNED_RULES },
    {
      name: 'expo-tooling/node',
      files: [...NODE_FILES, ...nodeFiles],
      languageOptions: { globals: globals.node },
    },
  ]);
}
