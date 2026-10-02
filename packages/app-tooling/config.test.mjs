import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ConfigError, CONFIG_FILE, PREBUILD_ASSERTIONS, prebuildConfig, readSection, SECTIONS, stringList, stringMap, testScriptsConfig } from './lib/config.mjs';

const tree = (files) => (file) => files[file] ?? null;
const at = (text) => tree({ '/r/app-tooling.json': text });

test('the family has one file, with a section per program', () => {
  assert.equal(CONFIG_FILE, 'app-tooling.json');
  assert.deepEqual(SECTIONS, {
    testSiblings: ['sources', 'exclude', 'mirror'],
    docs: ['architecture', 'allowTargetNames'],
    appSuites: ['skip'],
    prebuild: ['scenarios', 'exclude', 'command'],
    testScripts: ['sources', 'tests'],
  });
});

test('a section that is there is returned, and a missing file or section reads as none', () => {
  const read = at('{"docs":{"architecture":["scripts/"]},"testSiblings":{}}');
  assert.deepEqual(readSection('/r', 'docs', read), { architecture: ['scripts/'] });
  assert.deepEqual(readSection('/r', 'testSiblings', read), {});
  assert.equal(readSection('/r', 'docs', at('{"testSiblings":{}}')), null);
  assert.equal(readSection('/r', 'docs', tree({})), null);
});

test('a file that is there and wrong is a ConfigError naming the file and the reason', () => {
  for (const [text, reason] of [
    ['{', /^app-tooling\.json: not valid JSON: /],
    ['[]', /^app-tooling\.json: the top level must be an object of sections$/],
    ['null', /the top level must be an object of sections/],
    ['{"doc":{}}', /^app-tooling\.json: unknown section "doc"; the sections are testSiblings, docs, appSuites, prebuild, testScripts$/],
    ['{"docs":[]}', /^app-tooling\.json: "docs" must be an object$/],
    ['{"docs":{"architecture":[],"allow":{}}}', /^app-tooling\.json: unknown key "docs\.allow"; "docs" takes architecture, allowTargetNames$/],
  ]) {
    assert.throws(() => readSection('/r', 'docs', at(text)), (e) => e instanceof ConfigError && reason.test(e.message), text);
  }
});

test('stringList and stringMap hold a field to its type', () => {
  assert.deepEqual(stringList(['a'], 'x.y'), ['a']);
  for (const bad of ['a', [''], [1], null]) {
    assert.throws(() => stringList(bad, 'x.y'), (e) => e instanceof ConfigError && e.message === 'app-tooling.json: "x.y" must be a list of non-empty strings');
  }
  assert.deepEqual(stringMap({ a: 'b' }, 'x.y'), { a: 'b' });
  for (const bad of [['a'], { a: ' ' }, { a: 1 }, null]) {
    assert.throws(() => stringMap(bad, 'x.y'), (e) => e instanceof ConfigError && e.message === 'app-tooling.json: "x.y" must be an object of non-empty strings');
  }
});

const scenario = (assertions, extra = {}) => ({ scenarios: { default: { assert: assertions, ...extra } } });

test('a prebuild section is filled in: the default command, the label from the name, each assertion by kind', () => {
  const config = prebuildConfig({
    exclude: ['vendor'],
    scenarios: {
      default: {
        label: 'OTA off',
        env: { APP_VERSION: '1.2.3' },
        assert: [
          { file: 'ios/*/Info.plist', contains: 'AppBuildStamp', message: 'no stamp' },
          { file: 'a', absent: 'x' },
          { file: 'b', pattern: 'a\\s*b' },
          { exists: 'ios/**/Splash.colorset' },
        ],
      },
      ota: { assert: [{ file: 'c', contains: 'y' }] },
    },
  });
  assert.deepEqual(config.exclude, ['vendor']);
  assert.deepEqual(config.command, ['./node_modules/.bin/expo', 'prebuild', '--platform', 'all', '--clean', '--no-install']);
  assert.deepEqual(config.scenarios[0], {
    name: 'default',
    label: 'OTA off',
    env: { APP_VERSION: '1.2.3' },
    assertions: [
      { kind: 'contains', value: 'AppBuildStamp', file: 'ios/*/Info.plist', message: 'no stamp' },
      { kind: 'absent', value: 'x', file: 'a', message: null },
      { kind: 'pattern', value: 'a\\s*b', file: 'b', message: null },
      { kind: 'exists', value: 'ios/**/Splash.colorset', file: null, message: null },
    ],
  });
  assert.equal(config.scenarios[1].label, 'ota');
  assert.deepEqual(config.scenarios[1].env, {});
  assert.deepEqual(prebuildConfig({ ...scenario([{ exists: 'x' }]), command: ['node', 'p.mjs'] }).command, ['node', 'p.mjs']);
  assert.deepEqual(Object.keys(PREBUILD_ASSERTIONS), ['contains', 'absent', 'pattern', 'exists']);
});

test('a prebuild section that is wrong is a ConfigError naming the key and what it takes', () => {
  for (const [section, reason] of [
    [null, /no "prebuild" section/],
    [{}, /"prebuild\.scenarios" must be an object with at least one scenario/],
    [{ scenarios: {} }, /"prebuild\.scenarios" must be an object with at least one scenario/],
    [{ scenarios: [] }, /"prebuild\.scenarios" must be an object/],
    [{ ...scenario([{ exists: 'x' }]), command: [] }, /"prebuild\.command" must name a program/],
    [{ ...scenario([{ exists: 'x' }]), command: 'expo' }, /"prebuild\.command" must be a list/],
    [{ ...scenario([{ exists: 'x' }]), exclude: 'vendor' }, /"prebuild\.exclude" must be a list/],
    [{ scenarios: { a: 1 } }, /"prebuild\.scenarios\.a" must be an object/],
    [{ scenarios: { a: { assert: [{ exists: 'x' }], envs: {} } } }, /unknown key "prebuild\.scenarios\.a\.envs"; a scenario takes label, env, assert/],
    [{ scenarios: { a: { label: 1, assert: [{ exists: 'x' }] } } }, /"prebuild\.scenarios\.a\.label" must be a string/],
    [{ scenarios: { a: { env: { A: 1 }, assert: [{ exists: 'x' }] } } }, /"prebuild\.scenarios\.a\.env" must be an object of non-empty strings/],
    [{ scenarios: { a: {} } }, /"prebuild\.scenarios\.a\.assert" must be a list with at least one assertion/],
    [{ scenarios: { a: { assert: [] } } }, /must be a list with at least one assertion/],
    [scenario(['x']), /"prebuild\.scenarios\.default\.assert\[0\]" must be an object/],
    [scenario([{ file: 'a' }]), /\.assert\[0\]" needs exactly one of contains, absent, pattern, exists/],
    [scenario([{ file: 'a', contains: 'x', absent: 'y' }]), /needs exactly one of/],
    [scenario([{ file: 'a', contains: 'x', msg: 'm' }]), /unknown key "prebuild\.scenarios\.default\.assert\[0\]\.msg"; "contains" takes contains, file, message/],
    [scenario([{ exists: 'x', file: 'a' }]), /unknown key .*\.file"; "exists" takes exists, message/],
    [scenario([{ file: 'a', contains: '' }]), /\.contains" must be a non-empty string/],
    [scenario([{ file: 'a', contains: 1 }]), /\.contains" must be a non-empty string/],
    [scenario([{ file: 'a', pattern: '(' }]), /\.pattern" is not a regular expression/],
    [scenario([{ contains: 'x' }]), /\.file" must name the files to look in/],
    [scenario([{ file: '', contains: 'x' }]), /\.file" must name the files to look in/],
    [scenario([{ file: 'a', contains: 'x', message: 1 }]), /\.message" must be a string/],
  ]) {
    assert.throws(() => prebuildConfig(section), (e) => e instanceof ConfigError && reason.test(e.message), JSON.stringify(section));
  }
});

test('the testScripts section defaults to scripts/ and is checked when given', () => {
  const defaults = { sources: ['scripts/**/*.mjs'], tests: ['scripts/**/*.test.mjs'] };
  assert.deepEqual(testScriptsConfig(null), defaults);
  assert.deepEqual(testScriptsConfig({}), defaults);
  assert.deepEqual(testScriptsConfig({ sources: ['tools/**/*.mjs'], tests: ['tools/**/*.test.mjs', 'tools/*.spec.mjs'] }), {
    sources: ['tools/**/*.mjs'],
    tests: ['tools/**/*.test.mjs', 'tools/*.spec.mjs'],
  });
  for (const [section, reason] of [
    [{ sources: [] }, /"testScripts\.sources" must name at least one path pattern/],
    [{ tests: [] }, /"testScripts\.tests" must name at least one path pattern/],
    [{ sources: 'scripts' }, /"testScripts\.sources" must be a list of non-empty strings/],
    [{ tests: [''] }, /"testScripts\.tests" must be a list of non-empty strings/],
  ]) {
    assert.throws(() => testScriptsConfig(section), (e) => e instanceof ConfigError && reason.test(e.message), JSON.stringify(section));
  }
});
