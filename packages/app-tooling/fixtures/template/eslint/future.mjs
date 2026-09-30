// ESLint owns only React and Expo semantic rules; Biome owns the rest. The
// preset holds the split (see docs/quality.md); this file holds this app's paths.
import { createEslintConfig } from '@blinkbitcoin/app-tooling/expo/eslint';

export default createEslintConfig({
  ignores: ['src/graphql/generated/**', 'src/i18n/locales/**/messages.ts'],
  nodeFiles: ['mocks/server.ts'],
});
