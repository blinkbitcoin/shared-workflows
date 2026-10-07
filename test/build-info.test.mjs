// scripts/release/build-info.mjs: the program that assembles build-info.json for
// scripts/release/build-info.sh (and, as a byte-identical copy, for the package's
// release/build-info.sh).
//
// Covered here: the installed version of a package (installed, installed with
// no version field, not installed, no package.json at the root at all), the
// record (every key from the environment, in schema order, the empty and unset
// fingerprints and run id as null, a build number that is not a number), the
// serialized form, and every way out of main - the record written, the wrong
// number of arguments, a destination that cannot be written - plus the program
// run as a program and imported, when it runs nothing. test/build-info.bats runs
// it through the shell script, which is what a release does.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { USAGE, buildRecord, installedVersion, main, serialize } from '../scripts/release/build-info.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts/release/build-info.mjs');

const scratch = mkdtempSync(path.join(tmpdir(), 'build-info-'));
after(() => rmSync(scratch, { recursive: true, force: true }));

let consumers = 0;
/** A consumer root holding package.json and `packages` ({ name: package.json body }). */
function consumer(packages = {}) {
  const root = path.join(scratch, `consumer-${consumers++}`);
  mkdirSync(root, { recursive: true });
  writeFileSync(path.join(root, 'package.json'), '{"name":"consumer"}\n');
  for (const [name, body] of Object.entries(packages)) {
    mkdirSync(path.join(root, 'node_modules', name), { recursive: true });
    writeFileSync(path.join(root, 'node_modules', name, 'package.json'), JSON.stringify(body));
  }
  return root;
}

/** A writable stream stand-in that keeps what was written. */
function sink() {
  return { text: '', write(chunk) { this.text += chunk; } };
}

const FULL_ENV = {
  BUILD_INFO_SHA: 'deadbeef',
  APP_VERSION: '1.2.3',
  APP_BUILD_NUMBER: '1042',
  BUILD_INFO_STAGE: 'beta',
  FINGERPRINT_IOS: 'fp-i',
  FINGERPRINT_ANDROID: 'fp-a',
  GITHUB_RUN_ID: '99',
};

test('installedVersion reads the installed package, not the declared range', () => {
  const root = consumer({ expo: { name: 'expo', version: '54.0.7' } });
  assert.equal(installedVersion(root, 'expo'), '54.0.7');
});

test('installedVersion is null for a package installed without a version', () => {
  const root = consumer({ expo: { name: 'expo' } });
  assert.equal(installedVersion(root, 'expo'), null);
});

test('installedVersion is null for a package that is not installed', () => {
  assert.equal(installedVersion(consumer(), 'react-native'), null);
});

test('installedVersion is null when the root has no package.json at all', () => {
  const root = path.join(scratch, 'empty');
  mkdirSync(root, { recursive: true });
  assert.equal(installedVersion(root, 'expo'), null);
});

test('buildRecord takes every key from the environment, in schema order', () => {
  const asked = [];
  const record = buildRecord(FULL_ENV, (name) => {
    asked.push(name);
    return `${name}-version`;
  });
  assert.deepEqual(record, {
    sha: 'deadbeef',
    version: '1.2.3',
    buildNumber: 1042,
    stage: 'beta',
    fingerprint: { ios: 'fp-i', android: 'fp-a' },
    expoSdk: 'expo-version',
    reactNative: 'react-native-version',
    workflowRunId: '99',
    artifacts: {},
  });
  assert.deepEqual(Object.keys(record), [
    'sha', 'version', 'buildNumber', 'stage', 'fingerprint', 'expoSdk', 'reactNative', 'workflowRunId', 'artifacts',
  ]);
  assert.deepEqual(asked, ['expo', 'react-native']);
});

test('buildRecord gives null for an unset or empty fingerprint and run id', () => {
  const record = buildRecord({ ...FULL_ENV, FINGERPRINT_IOS: '', FINGERPRINT_ANDROID: undefined, GITHUB_RUN_ID: '' }, () => null);
  assert.deepEqual(record.fingerprint, { ios: null, android: null });
  assert.equal(record.workflowRunId, null);
  assert.equal(record.expoSdk, null);
});

test('buildRecord keeps a build number that is not a number as NaN, which the file shows as null', () => {
  const record = buildRecord({ ...FULL_ENV, APP_BUILD_NUMBER: 'x7' }, () => null);
  assert.ok(Number.isNaN(record.buildNumber));
  assert.match(serialize(record), /"buildNumber": null,/);
});

test('serialize writes two-space JSON with a final newline', () => {
  assert.equal(serialize({ a: 1, b: { c: null } }), '{\n  "a": 1,\n  "b": {\n    "c": null\n  }\n}\n');
});

test('main writes the record for the consumer at the root it is given', () => {
  const root = consumer({ expo: { version: '54.0.7' }, 'react-native': { version: '0.81.9' } });
  const dest = path.join(scratch, 'main-ok.json');
  const stderr = sink();
  assert.equal(main([dest, root], { env: FULL_ENV, stderr }), 0);
  const record = JSON.parse(readFileSync(dest, 'utf8'));
  assert.equal(record.expoSdk, '54.0.7');
  assert.equal(record.reactNative, '0.81.9');
  assert.equal(record.sha, 'deadbeef');
  assert.equal(stderr.text, '');
});

test('main refuses the wrong number of arguments, naming its usage, and writes nothing', () => {
  for (const argv of [[], ['only-dest'], ['a', 'b', 'c']]) {
    const stderr = sink();
    let wrote = false;
    assert.equal(main(argv, { env: FULL_ENV, stderr, write: () => { wrote = true; } }), 2);
    assert.equal(stderr.text, `::error::${USAGE}\n`);
    assert.equal(wrote, false);
  }
});

test('main fails, naming the destination, when the record cannot be written', () => {
  const dest = path.join(scratch, 'no-such-dir', 'build-info.json');
  const stderr = sink();
  assert.equal(main([dest, consumer()], { env: FULL_ENV, stderr }), 1);
  assert.match(stderr.text, new RegExp(`^::error::cannot write ${dest.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}: ENOENT`));
});

test('run as a program it writes the record from its environment and exits 0', () => {
  const root = consumer({ expo: { version: '54.0.7' } });
  const dest = path.join(scratch, 'program.json');
  const result = spawnSync(process.execPath, [SCRIPT, dest, root], {
    encoding: 'utf8',
    env: { PATH: process.env.PATH, ...FULL_ENV },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(dest, 'utf8'), serialize(buildRecord(FULL_ENV, (name) => installedVersion(root, name))));
});

test('run as a program with no arguments it exits 2 with its usage', () => {
  const result = spawnSync(process.execPath, [SCRIPT], { encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.equal(result.stderr, `::error::${USAGE}\n`);
});

test('imported, it runs nothing', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(SCRIPT)});`], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
});
