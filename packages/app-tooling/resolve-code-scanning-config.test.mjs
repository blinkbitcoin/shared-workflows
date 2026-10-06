import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main, parseArgs } from './bin/resolve-code-scanning-config.mjs';
import { yamlList } from './lib/codeql-config.mjs';

const BIN = fileURLToPath(new URL('./bin/resolve-code-scanning-config.mjs', import.meta.url));
let work;
before(() => {
  work = mkdtempSync(path.join(tmpdir(), 'resolve-code-scanning-'));
});
after(() => {
  rmSync(work, { recursive: true, force: true });
});

const repo = (own) => {
  const dir = mkdtempSync(path.join(work, 'repo-'));
  if (own !== undefined) {
    mkdirSync(path.join(dir, '.github', 'codeql'), { recursive: true });
    writeFileSync(path.join(dir, '.github', 'codeql', 'codeql-config.yml'), own);
  }
  return dir;
};
const run = (dir, argv) => {
  const out = { log: [], error: [] };
  const code = main(argv, { cwd: dir, log: (line) => out.log.push(line), error: (line) => out.error.push(line) });
  return { code, ...out };
};

test('parseArgs reads every option, wants --out, refuses anything else', () => {
  assert.deepEqual(parseArgs(['--out', 'o.yml'], '/w'), { root: '/w', config: '.github/codeql/codeql-config.yml', out: 'o.yml' });
  assert.deepEqual(parseArgs(['--root', 'app', '--config', 'c.yml', '--out', 'o.yml'], '/w'), { root: path.resolve('/w', 'app'), config: 'c.yml', out: 'o.yml' });
  assert.throws(() => parseArgs([], '/w'), /no --out: pass --out FILE/);
  assert.throws(() => parseArgs(['--out'], '/w'), /unexpected --out: pass --out FILE/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/w'), /unexpected --nope x: pass --out FILE/);
});

test('a repository with no file of its own gets the family defaults', () => {
  const dir = repo();
  const r = run(dir, ['--out', '.codeql-config.yml']);
  assert.deepEqual(r, { code: 0, log: ['resolved the family defaults (no .github/codeql/codeql-config.yml in this repository) into .codeql-config.yml'], error: [] });
  assert.ok(yamlList(readFileSync(path.join(dir, '.codeql-config.yml'), 'utf8'), 'paths-ignore').includes('.workflows'));
});

test('its own file is merged over the defaults, and the output directory is created', () => {
  const dir = repo('paths-ignore:\n  - generated\n');
  const r = run(dir, ['--out', 'out/merged.yml']);
  assert.equal(r.code, 0);
  assert.deepEqual(r.log, ['resolved the family defaults with .github/codeql/codeql-config.yml into out/merged.yml']);
  assert.ok(yamlList(readFileSync(path.join(dir, 'out', 'merged.yml'), 'utf8'), 'paths-ignore').includes('generated'));
});

test('a key the merge does not carry fails, and nothing is written', () => {
  const dir = repo('paths:\n  - src\n');
  const r = run(dir, ['--out', 'o.yml']);
  assert.equal(r.code, 1);
  assert.match(r.error[0], /^::error::\.github\/codeql\/codeql-config\.yml sets paths, which the merge/);
  assert.ok(!existsSync(path.join(dir, 'o.yml')));
});

test('a file that cannot be read for another reason than being absent fails', () => {
  const dir = repo();
  mkdirSync(path.join(dir, '.github', 'codeql', 'codeql-config.yml'), { recursive: true });
  const r = run(dir, ['--out', 'o.yml']);
  assert.equal(r.code, 1);
  assert.match(r.error[0], /^::error::\.github\/codeql\/codeql-config\.yml could not be read: /);
});

test('a bad argument is refused with the usage', () => {
  const r = run(work, ['--nope']);
  assert.equal(r.code, 1);
  assert.equal(r.error[0], 'resolve-code-scanning-config: unexpected --nope: pass --out FILE, and optionally --root DIR and --config FILE');
});

test('as a command it runs in --root', () => {
  const dir = repo();
  const child = spawnSync(process.execPath, [BIN, '--root', dir, '--out', 'o.yml'], { encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr);
  assert.ok(existsSync(path.join(dir, 'o.yml')));
  chmodSync(path.join(dir, 'o.yml'), 0o644);
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line) });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +resolve-code-scanning-config(?: |$)/m);
  assert.deepEqual(err, []);
});
