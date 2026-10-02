import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ConfigError, CONFIG_FILE, portTable, readSection, SECTIONS, stringList, stringMap } from './lib/config.mjs';

const tree = (files) => (file) => files[file] ?? null;
const at = (text) => tree({ '/r/app-tooling.json': text });

test('the family has one file, with a section per program', () => {
  assert.equal(CONFIG_FILE, 'app-tooling.json');
  assert.deepEqual(SECTIONS, {
    testSiblings: ['sources', 'exclude', 'mirror'],
    docs: ['architecture', 'allowTargetNames'],
    appSuites: ['skip'],
    ports: ['base', 'services', 'apiPath', 'allow', 'retired'],
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
    ['{"doc":{}}', /^app-tooling\.json: unknown section "doc"; the sections are testSiblings, docs, appSuites, ports$/],
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

test('a port table is validated, and absent means the family default', () => {
  assert.deepEqual(portTable(null), {});
  assert.deepEqual(portTable({}), {});
  const services = { api: { offset: 1, env: 'API_PORT', what: 'the api' }, web: { offset: 2, env: 'WEB_PORT', what: 'the site' } };
  assert.deepEqual(portTable({ base: 9000, apiPath: '/q', services, allow: {} }), { base: 9000, apiPath: '/q', services });
  for (const [section, reason] of [
    [{ base: 0 }, /"ports\.base" must be a port number/],
    [{ base: '8080' }, /"ports\.base" must be a port number/],
    [{ base: 70000 }, /"ports\.base" must be a port number/],
    [{ apiPath: 'graphql' }, /"ports\.apiPath" must be a path starting with \//],
    [{ apiPath: 1 }, /"ports\.apiPath" must be a path starting with \//],
    [{ services: {} }, /"ports\.services" must be an object with at least one service/],
    [{ services: [] }, /"ports\.services" must be an object with at least one service/],
    [{ services: { a: { offset: 0, env: 'A_PORT', what: 'x' } } }, /"ports\.services\.a" needs an integer offset/],
    [{ services: { a: { offset: 1, env: 'a_port', what: 'x' } } }, /"ports\.services\.a" needs an integer offset/],
    [{ services: { a: { offset: 1, env: 'A_PORT' } } }, /"ports\.services\.a" needs an integer offset/],
    [{ services: { a: 3 } }, /"ports\.services\.a" needs an integer offset/],
    [{ services: { a: { offset: 1, env: 'A_PORT', what: 'x' }, b: { offset: 1, env: 'B_PORT', what: 'y' } } }, /the same offset/],
    [{ services: { a: { offset: 1, env: 'A_PORT', what: 'x' }, b: { offset: 2, env: 'A_PORT', what: 'y' } } }, /the same env variable/],
  ]) {
    assert.throws(() => portTable(section), (e) => e instanceof ConfigError && reason.test(e.message), JSON.stringify(section));
  }
});
