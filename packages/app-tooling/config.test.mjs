import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ConfigError, CONFIG_FILE, readSection, SECTIONS, stringList, stringMap } from './lib/config.mjs';

const tree = (files) => (file) => files[file] ?? null;
const at = (text) => tree({ '/r/app-tooling.json': text });

test('the family has one file, with a section per program', () => {
  assert.equal(CONFIG_FILE, 'app-tooling.json');
  assert.deepEqual(SECTIONS, { testSiblings: ['sources', 'exclude', 'mirror'], docs: ['architecture', 'allowTargetNames'] });
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
    ['{"doc":{}}', /^app-tooling\.json: unknown section "doc"; the sections are testSiblings, docs$/],
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
