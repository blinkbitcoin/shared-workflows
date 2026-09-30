import assert from 'node:assert/strict';
import { test } from 'node:test';
import { stubModules } from './fixtures/stubs/register.mjs';

// eslint, eslint-config-expo and globals are the app's; here they are
// stand-ins, the same ones for the template's file today and for the file it
// becomes. A preset loaded from a URL ending in `?object` gets the variant of
// eslint-config-expo that exports one object rather than an array.
stubModules({
  'eslint/config': 'eslint-config.mjs',
  'eslint-config-expo/flat.js': (parent) =>
    parent.endsWith('?object') ? 'eslint-config-expo-object.mjs' : 'eslint-config-expo-array.mjs',
  globals: 'globals.mjs',
});

const { BIOME_OWNED_RULES, createEslintConfig, IGNORES, NODE_FILES } = await import('./expo/eslint.mjs');
const { default: today } = await import('./fixtures/template/eslint/today.mjs');
const { default: future } = await import('./fixtures/template/eslint/future.mjs');

// A block's `name` is a label for ESLint's configuration inspector and changes
// nothing a run reports, and the order of plain ignore globs (none negated) is
// irrelevant, so both are normalised away before comparing.
const normalise = (config) =>
  config.map(({ name, ...block }) => (block.ignores ? { ...block, ignores: [...block.ignores].sort() } : block));

test("the template's future eslint.config.mjs produces today's configuration", () => {
  assert.deepStrictEqual(normalise(future), normalise(today));
});

test('no ignore glob is negated, which is what makes their order irrelevant', () => {
  for (const block of future) for (const glob of block.ignores ?? []) assert.ok(!glob.startsWith('!'), glob);
});

test('with no options the configuration is the generic one, in the order ESLint needs', () => {
  const [ignores, ...rest] = createEslintConfig();
  assert.deepEqual(ignores, { name: 'app-tooling/expo/ignores', ignores: IGNORES });
  const names = rest.map((block) => block.name);
  // Expo's preset first, then the rules Biome owns switched off over it, then Node's globals.
  assert.deepEqual(names, ['expo/base', 'expo/react', 'app-tooling/expo/biome-owned', 'app-tooling/expo/node']);
  assert.equal(rest[2].rules, BIOME_OWNED_RULES);
  assert.deepEqual(rest[3].files, NODE_FILES);
  assert.deepEqual(rest[3].languageOptions.globals, { process: 'readonly', require: 'readonly' });
});

test("an app's ignores and Node files are appended to the generic ones", () => {
  const config = createEslintConfig({ ignores: ['generated/**'], nodeFiles: ['server.ts'] });
  assert.deepEqual(config[0].ignores, [...IGNORES, 'generated/**']);
  assert.deepEqual(config.at(-1).files, [...NODE_FILES, 'server.ts']);
});

test('an eslint-config-expo that exports one object rather than an array is used as one block', async () => {
  const { createEslintConfig: withObject } = await import('./expo/eslint.mjs?object');
  assert.deepEqual(
    withObject().map((block) => block.name),
    ['app-tooling/expo/ignores', 'expo/single', 'app-tooling/expo/biome-owned', 'app-tooling/expo/node'],
  );
});

test('every rule Biome owns is switched off, and none of the React hooks rules is', () => {
  for (const [rule, level] of Object.entries(BIOME_OWNED_RULES)) {
    assert.equal(level, 'off', rule);
    assert.ok(!rule.startsWith('react-hooks/'), rule);
  }
});
