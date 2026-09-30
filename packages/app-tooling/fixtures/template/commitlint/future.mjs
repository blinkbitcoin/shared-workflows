// Conventional Commits with a closed scope list. PR titles are linted with
// the same config in CI because squash merges take the title as the message.
export default {
  extends: ['@blinkbitcoin/app-tooling/expo/commitlint'],
  rules: {
    'scope-enum': [
      2,
      'always',
      [
        'app',
        'ui',
        'i18n',
        'graphql',
        'native',
        'plugins',
        'config',
        'tooling',
        'ci',
        'release',
        'deps',
        'deps-dev',
        'docs',
        'e2e',
        'web',
      ],
    ],
  },
};
