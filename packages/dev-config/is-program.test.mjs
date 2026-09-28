import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { isProgram } from './lib/is-program.mjs';

// Real path: a module's own URL is always resolved, and the temporary directory
// may sit behind a link (it does on macOS).
const dir = realpathSync(mkdtempSync(path.join(tmpdir(), 'is-program-')));
after(() => rmSync(dir, { recursive: true, force: true }));
const file = path.join(dir, 'tool.mjs');
writeFileSync(file, '');

test('the module node was started with is the program', () => {
  assert.equal(isProgram(pathToFileURL(file).href, file), true);
});

test('a link to it, as node_modules/.bin holds, is the program too', () => {
  const link = path.join(dir, 'tool-link');
  symlinkSync(file, link);
  assert.equal(isProgram(pathToFileURL(file).href, link), true);
});

test('another script, no script, and a path that does not exist are not', () => {
  const other = path.join(dir, 'other.mjs');
  writeFileSync(other, '');
  assert.equal(isProgram(pathToFileURL(file).href, other), false);
  assert.equal(isProgram(pathToFileURL(file).href, undefined), false);
  assert.equal(isProgram(pathToFileURL(file).href, path.join(dir, 'absent.mjs')), false);
});
