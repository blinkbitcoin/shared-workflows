import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { collectRules, main, parseArgs, parseMakefile, recipeProblem } from './bin/check-make-recipes.mjs';

const BIN = fileURLToPath(new URL('./bin/check-make-recipes.mjs', import.meta.url));
const recipe = (...lines) => ({ recipe: lines.map((text, i) => ({ line: i + 2, text })) });

/** A `read` over an in-memory tree rooted at /repo. */
const tree = (files) => (file) => files[file] ?? null;
function run(files, argv = []) {
  const out = { log: [], error: [] };
  const code = main(argv, { cwd: '/repo', read: tree(files), log: (l) => out.log.push(l), error: (l) => out.error.push(l) });
  return { code, ...out };
}

test('parseMakefile reads rules, their recipe lines and plain includes', () => {
  const text = [
    'SHELL := bash',
    '.PHONY: check',
    'include make/shared.mk $(DIR)/x.mk',
    '-include local.mk',
    'check: check-code check-docs ## Every gate',
    '',
    'check-docs: ## Docs',
    '\tbash scripts/docs.sh',
    '# a comment keeps the rule open',
    '\t',
    'VAR = 1',
    '\torphan recipe line',
    'a b: ; @true',
  ].join('\n');
  const { rules, includes } = parseMakefile(text);
  assert.deepEqual(includes, ['make/shared.mk', 'local.mk']);
  assert.deepEqual(
    rules.map(({ target, line, recipe: lines }) => [target, line, lines.map((l) => l.text)]),
    [
      ['check', 5, []],
      ['check-docs', 7, ['bash scripts/docs.sh', '']],
      ['a', 13, [' @true']],
    ],
  );
});

test('an aggregate and every single-call shape pass', () => {
  assert.equal(recipeProblem(recipe()), null);
  for (const line of [
    'bash node_modules/@blinkbitcoin/dev-config/checks/i18n.sh',
    '@bash scripts/x.sh --flag $(ARGS)',
    '-node scripts/y.mjs',
    'pnpm exec check-diagrams --all',
    'pnpm exec @scope/tool',
    'pnpm typecheck',
    'pnpm run test:coverage',
  ]) {
    assert.equal(recipeProblem(recipe(line)), null, line);
  }
  assert.equal(recipeProblem(recipe('bash x.sh', '   ', '# note')), null);
});

test('two recipe lines, a continuation, shell logic and a bare command each fail', () => {
  assert.equal(recipeProblem(recipe('bash a.sh', 'bash b.sh')), 'has 2 recipe lines');
  assert.equal(recipeProblem(recipe('bash a.sh \\')), 'continues its recipe over several lines');
  for (const line of ['bash a.sh && bash b.sh', 'pnpm x || true', 'bash a.sh; true', 'pnpm x | tee y', 'bash a.sh > out', 'bash a.sh < in', 'bash `which x`.sh', 'bash $(shell ls).sh']) {
    assert.match(recipeProblem(recipe(line)), /^holds shell logic: /, line);
  }
  assert.equal(recipeProblem(recipe('gitleaks git .')), 'does not call a script or program: gitleaks git .');
  assert.equal(recipeProblem(recipe('bash script.py')), 'does not call a script or program: bash script.py');
});

test('parseArgs takes --root and reasoned --allow entries, and rejects anything else', () => {
  assert.deepEqual(parseArgs(['--root', 'app', '--allow', 'install=runs before node_modules exists'], '/w'), {
    root: path.resolve('/w', 'app'),
    allowed: new Map([['install', 'runs before node_modules exists']]),
  });
  assert.throws(() => parseArgs(['--allow', 'install='], '/w'), /unexpected --allow install=/);
  assert.throws(() => parseArgs(['--root'], '/w'), /unexpected --root/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/w'), /unexpected --nope x/);
});

test('collectRules follows includes from where make runs, once each, and reports a missing one', () => {
  const read = tree({
    '/repo/Makefile': 'include make/a.mk make/gone.mk\nroot:\n\tbash r.sh\n',
    '/repo/make/a.mk': 'include make/b.mk\na:\n\tbash a.sh\n',
    '/repo/make/b.mk': 'include make/a.mk\nb:\n\tbash b.sh\n',
  });
  const { rules, missing } = collectRules('/repo/Makefile', read);
  assert.deepEqual(
    rules.map((r) => [r.target, r.file]),
    [
      ['root', '/repo/Makefile'],
      ['a', '/repo/make/a.mk'],
      ['b', '/repo/make/b.mk'],
    ],
  );
  assert.deepEqual(missing, ['/repo/make/gone.mk']);
});

test('main passes a Makefile of single calls and aggregates', () => {
  const { code, log, error } = run({ '/repo/Makefile': 'check: a b\na:\n\tbash a.sh\nb:\n\tpnpm exec b\n' });
  assert.deepEqual({ code, log, error }, { code: 0, log: ['make recipes ok (3 targets)'], error: [] });
});

test('main names every recipe with logic, where it is and what to do, including in an included fragment', () => {
  const { code, error } = run({
    '/repo/Makefile': 'include shared.mk\nnotes:\n\tbash a.sh\n\tbash b.sh\n',
    '/repo/shared.mk': 'secrets:\n\tgitleaks git .\n',
  });
  assert.equal(code, 1);
  assert.deepEqual(error, [
    'Makefile:2 notes has 2 recipe lines: move the logic into a tested script and call that',
    'shared.mk:1 secrets does not call a script or program: gitleaks git .: move the logic into a tested script and call that',
    'make recipes: 2 problem(s)',
  ]);
});

test('an --allow spares its target, and one that no longer applies fails', () => {
  const files = { '/repo/Makefile': 'install:\n\tpnpm install && lefthook install\nok:\n\tbash ok.sh\n' };
  assert.equal(run(files, ['--allow', 'install=runs before node_modules exists']).code, 0);
  const stale = run(files, ['--allow', 'install=x', '--allow', 'ok=y', '--allow', 'gone=z']);
  assert.equal(stale.code, 1);
  assert.deepEqual(stale.error.slice(0, 2), [
    '--allow ok names no target with logic in its recipe; drop it',
    '--allow gone names no target with logic in its recipe; drop it',
  ]);
});

test('main fails on a missing include, a missing Makefile and a bad argument', () => {
  assert.deepEqual(run({ '/repo/Makefile': 'include gone.mk\n' }).error, [
    'gone.mk is included and does not exist',
    'make recipes: 1 problem(s)',
  ]);
  assert.deepEqual(run({}), { code: 1, log: [], error: ['make recipes: no Makefile in /repo'] });
  assert.equal(run({}, ['--nope']).code, 1);
});

const dirs = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

test('runs as a program against a real directory', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'make-recipes-'));
  dirs.push(root);
  writeFileSync(path.join(root, 'Makefile'), 'a:\n\tbash a.sh && true\n');
  const result = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Makefile:1 a holds shell logic/);
  const ok = spawnSync(process.execPath, [BIN], { cwd: root, encoding: 'utf8' });
  assert.equal(ok.status, 1);
});

test('the default reader treats a directory with no Makefile as missing', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'make-recipes-empty-'));
  dirs.push(root);
  const error = [];
  assert.equal(main([], { cwd: root, error: (line) => error.push(line) }), 1);
  assert.deepEqual(error, [`make recipes: no Makefile in ${root}`]);
});
