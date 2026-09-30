import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { BadgeError, COLORS } from './lib/badge.mjs';
import { writeSecurityBadge } from './lib/security-badge.mjs';

const tmp = mkdtempSync(path.join(tmpdir(), 'security-badge-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

test('writes security.svg and security.json from the verdict', () => {
  const outDir = path.join(tmp, 'a');
  const badge = writeSecurityBadge({
    outDir,
    verdict: '{"verdict":"fail","highest":"high","canBlock":true}',
  });
  assert.deepEqual(badge, { label: 'Security', message: 'failing', color: 'red' });
  assert.ok(readFileSync(path.join(outDir, 'security.svg'), 'utf8').includes(COLORS.red));
  assert.equal(
    JSON.parse(readFileSync(path.join(outDir, 'security.json'), 'utf8')).message,
    'failing',
  );
});

test('takes a label', () => {
  const badge = writeSecurityBadge({
    outDir: path.join(tmp, 'b'),
    label: 'Scan',
    verdict: '{"verdict":"pass"}',
  });
  assert.equal(badge.label, 'Scan');
});

test('an unrecognised verdict writes nothing', () => {
  const outDir = path.join(tmp, 'c');
  assert.throws(() => writeSecurityBadge({ outDir, verdict: '{"verdict":"nope"}' }), BadgeError);
  assert.throws(() => readFileSync(path.join(outDir, 'security.svg')));
});
