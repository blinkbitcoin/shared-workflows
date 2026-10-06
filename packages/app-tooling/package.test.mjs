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

// npm packs a LICENSE only from the package directory, never through a symlink,
// and a CHANGELOG.md only when `files` names it; release-please writes this
// component's changelog here, so a consumer reading the installed package finds it.
test('the package ships its README, CHANGELOG and LICENSE, the LICENSE the repository\'s own', () => {
  for (const file of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    assert.ok(pkg.files.includes(file), `${file} is not in the published file list`);
    assert.ok(existsSync(new URL(`./${file}`, import.meta.url)), `${file} is missing`);
  }
  assert.equal(read('./LICENSE'), read('../../LICENSE'), 'the package LICENSE is not the repository\'s');
  assert.match(read('./LICENSE'), new RegExp(`^${pkg.license} License\n`), `the LICENSE is not the ${pkg.license} license package.json names`);
});

test('each Expo preset module carries its type declarations', () => {
  const presets = readdirSync(new URL('./expo/', import.meta.url)).filter((name) => name.endsWith('.mjs'));
  assert.ok(presets.length > 0, 'no preset modules under expo/');
  for (const file of presets) {
    assert.ok(targets.includes(`./expo/${file.replace(/\.mjs$/, '.d.mts')}`), `expo/${file} has no declarations`);
  }
});

test('every Expo preset is exported under expo/, and nothing else is', () => {
  for (const [name, target] of Object.entries(pkg.exports)) {
    const files = typeof target === 'string' ? [target] : Object.values(target);
    const expo = name.startsWith('./expo/');
    for (const file of files) assert.equal(file.startsWith('./expo/'), expo, `${name} -> ${file}`);
  }
});

// The presets are CommonJS-loadable ES modules: an app's metro.config.js and
// fingerprint.config.js `require()` them, which node does without a flag from
// 22.12. One package, one floor, so the programs share it.
test('the engines floor is the one the presets need', () => {
  assert.deepEqual(pkg.engines, { node: '>=22.12' });
});

test('it bundles nothing: every tool a preset names is an optional peer dependency', () => {
  assert.equal(pkg.dependencies, undefined);
  assert.deepEqual(Object.keys(pkg.peerDependenciesMeta).sort(), Object.keys(pkg.peerDependencies).sort());
  for (const [name, meta] of Object.entries(pkg.peerDependenciesMeta)) assert.deepEqual(meta, { optional: true }, name);
});

test('release-please releases it as the one package component, from the version in its package.json', () => {
  const config = JSON.parse(read('../../release-please-config.json'));
  const manifest = JSON.parse(read('../../.release-please-manifest.json'));
  assert.equal(pkg.name, '@blinkbitcoin/app-tooling');
  assert.deepEqual(Object.keys(config.packages), ['.', 'packages/app-tooling']);
  assert.deepEqual(Object.keys(manifest), ['.', 'packages/app-tooling']);
  assert.equal(manifest['packages/app-tooling'], pkg.version);
  const entry = config.packages['packages/app-tooling'];
  assert.equal(entry['release-type'], 'node');
  assert.equal(entry['package-name'], pkg.name);
  assert.equal(entry.component, 'app-tooling');
});

// The consumer guide shows what each of the template's configuration files
// becomes. Those are the files the preset tests evaluate, so the guide must
// show them byte for byte: an example that drifted from the tested file would
// be a promise nothing checks.
test("the consumer guide shows each of the template's future configuration files exactly", () => {
  const guide = read('../../docs/consumer-guide.md');
  const start = guide.indexOf('\n## Expo presets\n');
  assert.notEqual(start, -1, 'the guide has an "Expo presets" section');
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
