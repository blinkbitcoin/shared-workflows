// ESLint owns ONLY React/Expo semantic rules (react-hooks incl. React Compiler
// rules, expo env-var rules). Biome owns formatting, import order and generic
// lint. Nothing is enabled in both. See docs/quality.md.
import { defineConfig, globalIgnores } from 'eslint/config';
import expoConfig from 'eslint-config-expo/flat.js';
import globals from 'globals';

export default defineConfig([
  globalIgnores([
    'ios/**',
    'android/**',
    '.expo/**',
    'dist/**',
    'coverage/**',
    'vendor/bundle/**', // Ruby gems installed by `bundle install` (fastlane, cocoapods)
    '.workflows/**',
    '.claude/worktrees/**', // other checkouts of this repository, see docs/quality.md
    'src/graphql/generated/**',
    'src/i18n/locales/**/messages.ts',
    'rules/**', // Semgrep fixtures: deliberately vulnerable code, scanned by semgrep --test, not ESLint
  ]),
  ...(Array.isArray(expoConfig) ? expoConfig : [expoConfig]),
  {
    rules: {
      // Biome-owned: turn off anything stylistic or ordering-related from the preset
      'import/order': 'off',
      'import/first': 'off',
      'import/no-duplicates': 'off',
      'prettier/prettier': 'off',

      // Biome-owned generic correctness/suspicious rules that overlap 1:1 with a
      // rule enabled by biome.json's `recommended` ruleset (or its react/test
      // domains). See docs/quality.md for the full overlap table. react-hooks/*
      // is deliberately NOT listed here: Biome's useExhaustiveDependencies and
      // useHookAtTopLevel are turned off in biome.json instead, so ESLint keeps
      // owning hooks rules (including the React Compiler ones with no Biome
      // equivalent).
      eqeqeq: 'off', // dup of Biome suspicious/noDoubleEquals
      'no-dupe-args': 'off', // dup of Biome suspicious/noDuplicateParameters
      'no-dupe-class-members': 'off', // dup of Biome suspicious/noDuplicateClassMembers
      'no-dupe-keys': 'off', // dup of Biome suspicious/noDuplicateObjectKeys
      'no-duplicate-case': 'off', // dup of Biome suspicious/noDuplicateCase
      'no-empty-pattern': 'off', // dup of Biome correctness/noEmptyPattern
      'no-redeclare': 'off', // dup of Biome suspicious/noRedeclare
      'no-unreachable': 'off', // dup of Biome correctness/noUnreachable
      'no-unsafe-negation': 'off', // dup of Biome suspicious/noUnsafeNegation
      'no-unused-labels': 'off', // dup of Biome correctness/noUnusedLabels
      'no-unused-vars': 'off', // dup of Biome correctness/noUnusedVariables
      'no-with': 'off', // dup of Biome suspicious/noWith
      'use-isnan': 'off', // dup of Biome correctness/useIsNan
      'valid-typeof': 'off', // dup of Biome correctness/useValidTypeof
      '@typescript-eslint/no-dupe-class-members': 'off', // dup of Biome suspicious/noDuplicateClassMembers
      '@typescript-eslint/no-redeclare': 'off', // dup of Biome suspicious/noRedeclare
      '@typescript-eslint/no-unused-vars': 'off', // dup of Biome correctness/noUnusedVariables
      '@typescript-eslint/no-useless-constructor': 'off', // dup of Biome complexity/noUselessConstructor
      '@typescript-eslint/no-extra-non-null-assertion': 'off', // dup of Biome suspicious/noExtraNonNullAssertion
      '@typescript-eslint/no-empty-object-type': 'off', // dup of Biome complexity/noBannedTypes
      '@typescript-eslint/no-wrapper-object-types': 'off', // dup of Biome complexity/noBannedTypes
      'react/jsx-key': 'off', // dup of Biome correctness/useJsxKeyInIterable (react domain)
      'react/jsx-no-comment-textnodes': 'off', // dup of Biome suspicious/noCommentText
      'react/jsx-no-duplicate-props': 'off', // dup of Biome suspicious/noDuplicateJsxProps
      'react/no-children-prop': 'off', // dup of Biome correctness/noChildrenProp (react domain)
      'react/no-danger-with-children': 'off', // dup of Biome security/noDangerouslySetInnerHtmlWithChildren (react domain)
      'react/no-render-return-value': 'off', // dup of Biome correctness/noRenderReturnValue (react domain)
      // react/no-unknown-property (JSX/DOM unknown-attribute check, e.g. class vs
      // className) stays ON: Biome's correctness/noUnknownProperty is CSS-only
      // (validates CSS property names in stylesheets) and cannot fire on JSX, so
      // there is no real overlap here.
    },
  },
  {
    files: ['babel.config.js', 'metro.config.js', 'scripts/**/*.mjs', 'mocks/server.ts'],
    languageOptions: { globals: globals.node },
  },
]);
