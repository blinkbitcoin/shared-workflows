import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { helpLines, main, parseArgs } from './bin/make-help.mjs';

const BIN = fileURLToPath(new URL('./bin/make-help.mjs', import.meta.url));
const tree = (files) => (file) => files[file] ?? null;
function run(files, { argv = [], env = {}, isTTY = false } = {}) {
  const out = { log: [], error: [] };
  const code = main(argv, {
    cwd: '/repo',
    read: tree(files),
    env,
    isTTY,
    log: (line) => out.log.push(line),
    error: (line) => out.error.push(line),
  });
  return { code, ...out };
}

test('helpLines sorts the documented targets, pads them to the longest, and keeps the last description', () => {
  const text = 'test: ## Tests\ncheck: lint ## Every gate\nlint:\n\ttrue\ntest: ## Unit tests\n';
  assert.deepEqual(helpLines(text), ['check  Every gate', 'test   Unit tests']);
  assert.deepEqual(helpLines(text, { colour: true }), ['\u001b[36mcheck\u001b[0m  Every gate', '\u001b[36mtest \u001b[0m  Unit tests']);
  assert.deepEqual(helpLines('lint:\n\ttrue\n'), []);
});

test('parseArgs takes --root, and refuses anything else', () => {
  assert.deepEqual(parseArgs(['--root', 'app'], '/w'), { root: path.resolve('/w', 'app') });
  assert.deepEqual(parseArgs([], '/w'), { root: '/w' });
  assert.throws(() => parseArgs(['--root'], '/w'), /unexpected --root: pass --root DIR/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/w'), /unexpected --nope x/);
});

test('main lists the targets of the Makefile and of the fragments it includes', () => {
  const { code, log, error } = run({
    '/repo/Makefile': 'include make/shared.mk\n-include local.mk\nhelp: ## Show this help\n',
    '/repo/make/shared.mk': 'check-docs: ## Docs\n',
  });
  assert.deepEqual({ code, log, error }, { code: 0, log: ['check-docs  Docs', 'help        Show this help'], error: [] });
});

test('main colours the names on a terminal, unless NO_COLOR is set', () => {
  const files = { '/repo/Makefile': 'help: ## Help\n' };
  assert.deepEqual(run(files, { isTTY: true }).log, ['\u001b[36mhelp\u001b[0m  Help']);
  assert.deepEqual(run(files, { isTTY: true, env: { NO_COLOR: '1' } }).log, ['help  Help']);
});

test('main fails on no Makefile, a Makefile with nothing documented, and a bad argument', () => {
  assert.deepEqual(run({}), { code: 1, log: [], error: ['make help: no Makefile in /repo'] });
  assert.deepEqual(run({ '/repo/Makefile': 'a:\n\ttrue\n' }), {
    code: 1,
    log: [],
    error: ['make help: no target in /repo/Makefile has a ## description'],
  });
  assert.deepEqual(run({}, { argv: ['--nope'] }).error, ['make help: unexpected --nope: pass --root DIR']);
});

const dirs = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

test('runs as a program against a real directory, plain when piped', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'make-help-'));
  dirs.push(root);
  writeFileSync(path.join(root, 'Makefile'), 'include extra.mk\nb: ## Bee\n');
  writeFileSync(path.join(root, 'extra.mk'), 'a: ## Ay\n');
  const result = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'a  Ay\nb  Bee\n');
  const empty = mkdtempSync(path.join(tmpdir(), 'make-help-empty-'));
  dirs.push(empty);
  const missing = spawnSync(process.execPath, [BIN], { cwd: empty, encoding: 'utf8' });
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /make help: no Makefile in /);
});
