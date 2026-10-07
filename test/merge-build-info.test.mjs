// scripts/release/merge-build-info.mjs: the program that folds each platform's
// build-info record into the release's, for scripts/release/merge-build-info.sh.
//
// Covered here: reading a record (JSON, not JSON, missing) and writing one, the
// precedence rule (only `artifacts` taken from an overlay, later overlays win
// key by key, a base or overlay with no `artifacts`, key order kept), and every
// way out of main - merged, too few arguments, an unreadable base, an unreadable
// overlay - plus the program run as a program and imported, when it runs
// nothing. test/merge-build-info.bats runs it through the shell script.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { USAGE, main, mergeArtifacts, readJson, writeJson } from '../scripts/release/merge-build-info.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts/release/merge-build-info.mjs');

const scratch = mkdtempSync(path.join(tmpdir(), 'merge-build-info-'));
after(() => rmSync(scratch, { recursive: true, force: true }));

/** Writes `text` to a file of that name in the scratch directory and returns its path. */
function file(name, text) {
  const at = path.join(scratch, name);
  writeFileSync(at, text);
  return at;
}

/** A writable stream stand-in that keeps what was written. */
function sink() {
  return { text: '', write(chunk) { this.text += chunk; } };
}

test('readJson parses the file it is given', () => {
  assert.deepEqual(readJson(file('ok.json', '{"sha":"abc"}')), { sha: 'abc' });
});

test('readJson names the file that is not JSON', () => {
  const at = file('garbage.json', 'garbage');
  assert.throws(() => readJson(at), { message: new RegExp(`^${at.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} is not readable as JSON: Unexpected token`) });
});

test('readJson names a file that is not there', () => {
  assert.throws(() => readJson('/no/such/build-info.json'), {
    message: /^\/no\/such\/build-info\.json is not readable as JSON: ENOENT/,
  });
});

test('writeJson writes two-space JSON with a final newline', () => {
  const writes = [];
  writeJson('out.json', { a: { b: 1 } }, (at, text) => writes.push([at, text]));
  assert.deepEqual(writes, [['out.json', '{\n  "a": {\n    "b": 1\n  }\n}\n']]);
});

test('mergeArtifacts takes only artifacts from each overlay, later ones winning key by key', () => {
  const merged = mergeArtifacts(
    { sha: 'this-run', stage: 'beta', artifacts: { dsymSha256: 'ddd', apkSha256: 'old' } },
    [
      { sha: 'stale', stage: 'internal', artifacts: { apkSha256: 'aaa' } },
      { artifacts: { ipaSha256: 'iii', apkSha256: 'last' } },
    ],
  );
  assert.deepEqual(merged, {
    sha: 'this-run',
    stage: 'beta',
    artifacts: { dsymSha256: 'ddd', apkSha256: 'last', ipaSha256: 'iii' },
  });
  // The existing key keeps its place; a new one is appended.
  assert.deepEqual(Object.keys(merged.artifacts), ['dsymSha256', 'apkSha256', 'ipaSha256']);
});

test('mergeArtifacts gives a base without artifacts an artifacts object, at the end', () => {
  const merged = mergeArtifacts({ sha: 'abc' }, [{ sha: 'other' }]);
  assert.deepEqual(merged, { sha: 'abc', artifacts: {} });
  assert.deepEqual(Object.keys(merged), ['sha', 'artifacts']);
});

test('mergeArtifacts keeps artifacts where the base has it', () => {
  const merged = mergeArtifacts({ artifacts: {}, sha: 'abc' }, [{ artifacts: { a: '1' } }]);
  assert.deepEqual(Object.keys(merged), ['artifacts', 'sha']);
});

test('mergeArtifacts leaves its arguments alone', () => {
  const base = { artifacts: { a: '1' } };
  mergeArtifacts(base, [{ artifacts: { b: '2' } }]);
  assert.deepEqual(base, { artifacts: { a: '1' } });
});

test('main rewrites the base in place with every overlay folded in', () => {
  const base = file('base.json', '{"sha":"this","artifacts":{"dsymSha256":"ddd"}}\n');
  const android = file('build-info.android.json', '{"sha":"stale","artifacts":{"apkSha256":"aaa"}}\n');
  const ios = file('build-info.ios.json', '{"artifacts":{"ipaSha256":"iii"}}\n');
  const stderr = sink();
  assert.equal(main([base, android, ios], { stderr }), 0);
  assert.equal(
    readFileSync(base, 'utf8'),
    '{\n  "sha": "this",\n  "artifacts": {\n    "dsymSha256": "ddd",\n    "apkSha256": "aaa",\n    "ipaSha256": "iii"\n  }\n}\n',
  );
  assert.equal(stderr.text, '');
});

test('main refuses fewer than a base and one overlay, naming its usage', () => {
  for (const argv of [[], ['base.json']]) {
    const stderr = sink();
    assert.equal(main(argv, { stderr }), 2);
    assert.equal(stderr.text, `::error::${USAGE}\n`);
  }
});

test('main fails naming an overlay that is not JSON, and leaves the base as it was', () => {
  const before = '{"sha":"abc","artifacts":{}}\n';
  const base = file('keep.json', before);
  const bad = file('build-info.bad.json', 'garbage');
  const stderr = sink();
  assert.equal(main([base, bad], { stderr }), 1);
  assert.match(stderr.text, /^::error::.*build-info\.bad\.json is not readable as JSON: /);
  assert.equal(readFileSync(base, 'utf8'), before);
});

test('main fails naming a base that is not JSON', () => {
  const base = file('bad-base.json', 'garbage');
  const stderr = sink();
  let wrote = false;
  assert.equal(main([base, file('o.json', '{}')], { stderr, write: () => { wrote = true; } }), 1);
  assert.match(stderr.text, /^::error::.*bad-base\.json is not readable as JSON: /);
  assert.equal(wrote, false);
});

test('run as a program it merges and exits 0', () => {
  const base = file('program-base.json', '{"sha":"abc"}\n');
  const overlay = file('program-overlay.json', '{"artifacts":{"apkSha256":"aaa"}}\n');
  const result = spawnSync(process.execPath, [SCRIPT, base, overlay], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(readFileSync(base, 'utf8')), { sha: 'abc', artifacts: { apkSha256: 'aaa' } });
});

test('run as a program on an unreadable overlay it exits 1 naming the file', () => {
  const base = file('program-base-2.json', '{}\n');
  const result = spawnSync(process.execPath, [SCRIPT, base, path.join(scratch, 'absent.json')], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /^::error::.*absent\.json is not readable as JSON: ENOENT/);
});

test('imported, it runs nothing', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(SCRIPT)});`], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
});
