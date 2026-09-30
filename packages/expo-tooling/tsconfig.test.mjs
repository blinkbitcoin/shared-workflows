import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const json = (path) => JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8'));
const base = json('./tsconfig.base.json');
const today = json('./fixtures/template/tsconfig/today.json');
const future = json('./fixtures/template/tsconfig/future.json');

// TypeScript applies an `extends` array in order, each later file's
// compilerOptions overriding the earlier ones option by option, and the
// extending file's own last; `include`, `exclude` and `files` come from the
// nearest file that sets them. Both files extend expo/tsconfig.base first, so
// it drops out of the comparison. Checked against `tsc --showConfig` on the
// template (TypeScript 6.0): the output of the two, file list included, is
// identical.
test("the template's future tsconfig.json keeps today's first base", () => {
  assert.equal(today.extends, 'expo/tsconfig.base');
  assert.deepEqual(future.extends, ['expo/tsconfig.base', '@blinkbitcoin/expo-tooling/tsconfig.base.json']);
});

test("its compilerOptions merged over this base's are today's", () => {
  assert.deepStrictEqual({ ...base.compilerOptions, ...future.compilerOptions }, today.compilerOptions);
});

test('it keeps include and exclude, which resolve against the file that declares them', () => {
  assert.deepStrictEqual(future.include, today.include);
  assert.deepStrictEqual(future.exclude, today.exclude);
});

test('the base declares nothing path-valued, which would resolve inside node_modules', () => {
  for (const key of ['include', 'exclude', 'files', 'references']) assert.equal(base[key], undefined, key);
  for (const key of ['baseUrl', 'paths', 'rootDir', 'rootDirs', 'typeRoots', 'outDir']) {
    assert.equal(base.compilerOptions[key], undefined, key);
  }
});

test("the base leaves ignoreDeprecations to the app: its value is tied to the app's TypeScript", () => {
  assert.equal(base.compilerOptions.ignoreDeprecations, undefined);
});
