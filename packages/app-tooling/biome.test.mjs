import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const json = (path) => JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8'));
const base = json('./expo/biome.json');
const today = json('./fixtures/template/biome/today.json');
const future = json('./fixtures/template/biome/future.json');

// How Biome 2 applies `extends`, measured with Biome 2.5.11 against a package
// exporting a base file (the three cases are in docs/consumer-guide.md,
// "Expo presets"): objects merge key by key, the extending file
// winning; arrays - `files.includes` and `overrides` - are CONCATENATED, the
// base's entries first. And the base's globs resolve against the project root
// (the directory of the app's biome.json), not against node_modules.
function merge(first, second) {
  if (Array.isArray(first) && Array.isArray(second)) return [...first, ...second];
  if (isObject(first) && isObject(second)) {
    const merged = { ...first };
    for (const [key, value] of Object.entries(second)) merged[key] = key in first ? merge(first[key], value) : value;
    return merged;
  }
  return second;
}
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

const effective = (() => {
  const { extends: _extends, $schema: _schema, ...own } = future;
  return merge(base, own);
})();

const TOOLING = ['scripts/**', 'plugins/**', 'mocks/**', '*.config.*', 'codegen.ts'];

// The template's switch deletes three files an override named (the console
// guard, its test, and the Expo stand-ins, all now in this package), and the
// base's tooling override now comes first rather than last.
function expectedFromToday() {
  const { $schema: _schema, ...expected } = structuredClone(today);
  const moved = ['src/test/console.ts', 'src/test/console.test.ts', 'src/test/mocks/**'];
  expected.overrides = expected.overrides.map((override) => ({
    ...override,
    includes: override.includes.filter((glob) => !moved.includes(glob)),
  }));
  const tooling = expected.overrides.findIndex((override) => override.includes.join() === TOOLING.join());
  assert.notEqual(tooling, -1, "today's file has the tooling override");
  expected.overrides.unshift(...expected.overrides.splice(tooling, 1));
  return expected;
}

test("the template's future biome.json, merged over this base, is today's", () => {
  assert.deepStrictEqual(effective, expectedFromToday());
});

test("moving the tooling override first changes nothing: no other override's files are tooling files", () => {
  const others = effective.overrides.slice(1).flatMap((override) => override.includes);
  assert.ok(others.length > 0);
  for (const glob of others) assert.ok(glob.startsWith('src/'), `${glob} could overlap the tooling paths`);
});

test('files.includes: the base starts with the catch-all, the app only adds exclusions', () => {
  // A second `**` in the app's list would put back everything the base
  // excluded before it (Biome's noBiomeFirstException flags exactly that).
  assert.equal(base.files.includes[0], '**');
  for (const glob of future.files.includes) assert.ok(glob.startsWith('!'), glob);
});

test('the base pins no schema version, so it never disagrees with the app\'s Biome', () => {
  assert.equal(base.$schema, undefined);
  assert.equal(base.extends, undefined);
});

test('the merge the comparison relies on concatenates arrays and merges objects', () => {
  assert.deepEqual(merge({ a: [1], b: { c: 1, d: 1 }, e: 1 }, { a: [2], b: { d: 2 }, f: 2 }), {
    a: [1, 2],
    b: { c: 1, d: 2 },
    e: 1,
    f: 2,
  });
  assert.equal(merge({ a: 1 }, 'scalar'), 'scalar');
});
