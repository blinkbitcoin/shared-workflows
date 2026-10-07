// scripts/release/artifact-hashes.mjs: the program that writes the copy of a
// build-info record carrying a platform's binary digests, for
// scripts/release/artifact-hashes.sh.
//
// Covered here: the NAME=SHA256 arguments (several, in order, an empty digest
// left out, a digest holding `=`, no `=` at all, no name), the merge into
// `artifacts` (kept entries, a source with none, key order), and every way out
// of main - written, too few arguments, a malformed pair, a source that is not
// JSON, a destination that cannot be written - plus the program run as a
// program and imported, when it runs nothing. test/artifact-hashes.bats runs it
// through the shell script, for each platform.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { USAGE, main, parseDigests, withArtifacts } from '../scripts/release/artifact-hashes.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts/release/artifact-hashes.mjs');

const scratch = mkdtempSync(path.join(tmpdir(), 'artifact-hashes-'));
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

test('parseDigests keeps each named digest, in the order given', () => {
  const digests = parseDigests(['apkSha256=aaa', 'aabSha256=bbb']);
  assert.deepEqual(digests, { apkSha256: 'aaa', aabSha256: 'bbb' });
  assert.deepEqual(Object.keys(digests), ['apkSha256', 'aabSha256']);
});

test('parseDigests leaves out a binary with no digest rather than recording it empty', () => {
  assert.deepEqual(parseDigests(['apkSha256=', 'aabSha256=bbb']), { aabSha256: 'bbb' });
  assert.deepEqual(parseDigests([]), {});
});

test('parseDigests splits at the first =, so a digest may hold one', () => {
  assert.deepEqual(parseDigests(['ipaSha256=a=b']), { ipaSha256: 'a=b' });
});

test('parseDigests refuses a pair with no = or no name', () => {
  assert.throws(() => parseDigests(['apkSha256']), { message: 'not NAME=SHA256: "apkSha256"' });
  assert.throws(() => parseDigests(['=aaa']), { message: 'not NAME=SHA256: "=aaa"' });
});

test('withArtifacts merges into the artifacts already there, new keys after them', () => {
  const merged = withArtifacts(
    { sha: 'abc', artifacts: { keep: 'me', apkSha256: 'old' } },
    { apkSha256: 'new', aabSha256: 'bbb' },
  );
  assert.deepEqual(merged, { sha: 'abc', artifacts: { keep: 'me', apkSha256: 'new', aabSha256: 'bbb' } });
  assert.deepEqual(Object.keys(merged.artifacts), ['keep', 'apkSha256', 'aabSha256']);
});

test('withArtifacts gives a record without artifacts an artifacts object, at the end', () => {
  const merged = withArtifacts({ sha: 'abc' }, {});
  assert.deepEqual(merged, { sha: 'abc', artifacts: {} });
  assert.deepEqual(Object.keys(merged), ['sha', 'artifacts']);
});

test('main writes the enriched copy and leaves the source alone', () => {
  const source = file('source.json', '{"sha":"abc","artifacts":{}}\n');
  const dest = path.join(scratch, 'dest.json');
  const stderr = sink();
  assert.equal(main([source, dest, 'apkSha256=aaa', 'aabSha256='], { stderr }), 0);
  assert.equal(readFileSync(dest, 'utf8'), '{\n  "sha": "abc",\n  "artifacts": {\n    "apkSha256": "aaa"\n  }\n}\n');
  assert.equal(readFileSync(source, 'utf8'), '{"sha":"abc","artifacts":{}}\n');
  assert.equal(stderr.text, '');
});

test('main with no digests still writes the copy', () => {
  const source = file('source-2.json', '{"sha":"abc"}\n');
  const dest = path.join(scratch, 'dest-2.json');
  assert.equal(main([source, dest], { stderr: sink() }), 0);
  assert.deepEqual(JSON.parse(readFileSync(dest, 'utf8')), { sha: 'abc', artifacts: {} });
});

test('main refuses fewer than a source and a destination, naming its usage', () => {
  for (const argv of [[], ['source.json']]) {
    const stderr = sink();
    assert.equal(main(argv, { stderr }), 2);
    assert.equal(stderr.text, `::error::${USAGE}\n`);
  }
});

test('main refuses a malformed pair before reading anything', () => {
  const stderr = sink();
  let read = false;
  assert.equal(main(['s.json', 'd.json', 'apk'], { stderr, read: () => { read = true; } }), 2);
  assert.equal(stderr.text, `::error::not NAME=SHA256: "apk" (${USAGE})\n`);
  assert.equal(read, false);
});

test('main fails naming a source that is not JSON, and writes nothing', () => {
  const source = file('garbage.json', 'not json');
  const stderr = sink();
  let wrote = false;
  assert.equal(main([source, 'd.json', 'apkSha256=aaa'], { stderr, write: () => { wrote = true; } }), 1);
  assert.match(stderr.text, /^::error::.*garbage\.json is not readable as JSON: Unexpected token/);
  assert.equal(wrote, false);
});

test('main fails when the copy cannot be written', () => {
  const source = file('source-3.json', '{}\n');
  const stderr = sink();
  assert.equal(main([source, path.join(scratch, 'no-such-dir', 'dest.json')], { stderr }), 1);
  assert.match(stderr.text, /^::error::ENOENT/);
});

test('run as a program it writes the copy and exits 0', () => {
  const source = file('program-source.json', '{"sha":"abc"}\n');
  const dest = path.join(scratch, 'program-dest.json');
  const result = spawnSync(process.execPath, [SCRIPT, source, dest, 'ipaSha256=iii'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(readFileSync(dest, 'utf8')), { sha: 'abc', artifacts: { ipaSha256: 'iii' } });
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
