import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');
const pkg = JSON.parse(read('./package.json'));

/** Every file an export points at, `types` included. */
const targets = Object.values(pkg.exports).flatMap((target) =>
  typeof target === 'string' ? [target] : Object.values(target),
);

test('every export points at a file that exists', () => {
  for (const target of targets) assert.ok(existsSync(new URL(target, import.meta.url)), target);
});

test('every exported file is in the published file list', () => {
  const published = (target) =>
    target === './package.json' || pkg.files.some((entry) => target === `./${entry}` || target.startsWith(`./${entry}/`));
  for (const target of targets) assert.ok(published(target), target);
});

test('each preset module carries its type declarations', () => {
  for (const file of readdirSync(new URL('./lib/', import.meta.url)).filter((name) => name.endsWith('.mjs'))) {
    assert.ok(targets.includes(`./lib/${file.replace(/\.mjs$/, '.d.mts')}`), `lib/${file} has no declarations`);
  }
});

test('it bundles nothing: every tool a preset names is an optional peer dependency', () => {
  assert.equal(pkg.dependencies, undefined);
  assert.deepEqual(Object.keys(pkg.peerDependenciesMeta).sort(), Object.keys(pkg.peerDependencies).sort());
  for (const [name, meta] of Object.entries(pkg.peerDependenciesMeta)) assert.deepEqual(meta, { optional: true }, name);
});

test('release-please releases it as its own component, from the version in its package.json', () => {
  const config = JSON.parse(read('../../release-please-config.json'));
  const manifest = JSON.parse(read('../../.release-please-manifest.json'));
  assert.equal(pkg.name, '@blinkbitcoin/expo-tooling');
  assert.equal(manifest['packages/expo-tooling'], pkg.version);
  const entry = config.packages['packages/expo-tooling'];
  assert.equal(entry['release-type'], 'node');
  assert.equal(entry['package-name'], pkg.name);
  assert.equal(entry.component, 'expo-tooling');
});

// The consumer guide shows what each of the template's configuration files
// becomes. Those are the files the preset tests evaluate, so the guide must
// show them byte for byte: an example that drifted from the tested file would
// be a promise nothing checks.
test("the consumer guide shows each of the template's future configuration files exactly", () => {
  const guide = read('../../docs/consumer-guide.md');
  const start = guide.indexOf('\n## expo-tooling presets\n');
  assert.notEqual(start, -1, 'the guide has an "expo-tooling presets" section');
  const end = guide.indexOf('\n## ', start + 1);
  const section = guide.slice(start, end === -1 ? undefined : end);
  const blocks = [...section.matchAll(/^```[a-z]*\n([\s\S]*?)^```$/gm)].map(([, body]) => body);
  const dir = new URL('./fixtures/template/', import.meta.url);
  for (const tool of readdirSync(dir)) {
    const future = readdirSync(new URL(`${tool}/`, dir)).find((name) => name.startsWith('future.'));
    const text = readFileSync(new URL(`${tool}/${future}`, dir), 'utf8');
    assert.ok(blocks.includes(text), `the guide does not show fixtures/template/${tool}/${future} as it is`);
  }
});
