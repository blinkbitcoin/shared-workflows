import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  documentedTargets,
  main,
  miseTools,
  namedAfterTools,
  packageNames,
  parseArgs,
} from './bin/check-make-target-names.mjs';

const SCRIPT = fileURLToPath(new URL('./bin/check-make-target-names.mjs', import.meta.url));
const roots = [];
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

describe('the rule', () => {
  test('reads the documented targets, not the undocumented ones', () => {
    const makefile = 'check-unused: ## Unused code\n\tpnpm knip\nhidden:\n\ttrue\nci: check ## All\n';
    assert.deepEqual(documentedTargets(makefile), ['check-unused', 'ci']);
  });

  test("reads .mise.toml's tools, with and without a backend prefix", () => {
    const toml = '[env]\nA = "1"\n[tools]\nnode = "24"\n"pypi:mobsfscan" = "1"\n"aqua:org/zizmor" = "1"\n[settings]\nx = 1\n';
    assert.deepEqual(miseTools(toml), ['node', 'mobsfscan', 'zizmor']);
    assert.deepEqual(miseTools('[env]\nA = "1"\n'), []);
  });

  test('takes the unscoped packages from dependencies and devDependencies', () => {
    const pkg = { dependencies: { expo: '1', '@apollo/client': '1' }, devDependencies: { knip: '1' } };
    assert.deepEqual(packageNames(pkg), ['expo', 'knip']);
    assert.deepEqual(packageNames({}), []);
  });

  test('names a target with a tool word, and spares setup- targets and the allowed ones', () => {
    const found = namedAfterTools(
      ['check-knip', 'zizmor', 'check-unused', 'setup-maestro', 'gen-graphql'],
      ['knip', 'zizmor', 'maestro', 'graphql'],
      new Map([['gen-graphql', 'the thing generated']]),
    );
    assert.deepEqual(found, ['check-knip (knip)', 'zizmor (zizmor)']);
  });
});

test('arguments: a root, allowances with their reasons, and anything else refused', () => {
  assert.deepEqual(parseArgs(['--root', 'sub', '--allow', 'gen-graphql=what it generates'], '/repo'), {
    root: '/repo/sub',
    allowed: new Map([['gen-graphql', 'what it generates']]),
    requireMise: false,
  });
  assert.deepEqual(parseArgs([], '/repo'), { root: '/repo', allowed: new Map(), requireMise: false });
  // A flag with no value: the argument after it is read on its own.
  assert.deepEqual(parseArgs(['--require-mise', '--root', 'sub'], '/repo'), { root: '/repo/sub', allowed: new Map(), requireMise: true });
  assert.throws(() => parseArgs(['--allow', 'gen-graphql'], '/repo'), /unexpected --allow gen-graphql/);
  assert.throws(() => parseArgs(['--allow', 'gen-graphql= '], '/repo'), /unexpected --allow/);
  assert.throws(() => parseArgs(['--allow'], '/repo'), /unexpected --allow:/);
  assert.throws(() => parseArgs(['--root'], '/repo'), /unexpected --root:/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/repo'), /unexpected --nope x/);
});

const MAKEFILE = 'check-unused: ## Unused\n\ttrue\ngen-graphql: ## Codegen\n\ttrue\nsetup-maestro: ## Install\n\ttrue\n';
const MISE = '[tools]\nmaestro = "2"\n';
const PKG = JSON.stringify({ devDependencies: { knip: '1', graphql: '1', '@scope/x': '1' } });
const tree = (files) => (file) => files[path.basename(file)] ?? null;
const capture = () => {
  const out = [];
  const err = [];
  return { out, err, io: { log: (l) => out.push(l), error: (l) => err.push(l) } };
};

test('main passes a Makefile whose targets name what they do', () => {
  const { out, err, io } = capture();
  const read = tree({ Makefile: MAKEFILE, '.mise.toml': MISE, 'package.json': PKG });
  assert.equal(main(['--allow', 'gen-graphql=GraphQL is what it generates'], { ...io, cwd: '/r', read }), 0);
  assert.deepEqual(err, []);
  assert.deepEqual(out, ['make target names ok (3 targets, 3 tools)']);
});

test('main fails on a target named after a tool, and on allowances that no longer apply', () => {
  const { out, err, io } = capture();
  const read = tree({ Makefile: `${MAKEFILE}check-knip: ## Knip\n\ttrue\n`, 'package.json': PKG });
  const allow = ['--allow', 'gone=x', '--allow', 'check-unused=no tool here'];
  assert.equal(main(['--allow', 'gen-graphql=generated', ...allow], { ...io, cwd: '/r', read }), 1);
  assert.deepEqual(out, []);
  assert.deepEqual(err, [
    'check-knip (knip) is named after a tool: name it for what it checks or does, and put the tool in its ## description',
    '--allow gone names no documented make target; drop it',
    '--allow check-unused is no longer named after a tool; drop it',
    'make target names: 3 problem(s)',
  ]);
});

test('main follows include and -include to the fragments that exist, and holds their targets to the rule', () => {
  const { out, err, io } = capture();
  const read = tree({
    Makefile: `include shared.mk\n-include local.mk\n${MAKEFILE}`,
    'shared.mk': 'check-knip: ## Knip\n\ttrue\n',
    'package.json': PKG,
  });
  assert.equal(main(['--allow', 'gen-graphql=generated'], { ...io, cwd: '/r', read }), 1);
  assert.deepEqual(out, []);
  assert.match(err[0], /^check-knip \(knip\) is named after a tool/);
});

test('main works with neither a .mise.toml nor a package.json', () => {
  const { out, io } = capture();
  assert.equal(main([], { ...io, cwd: '/r', read: tree({ Makefile: MAKEFILE }) }), 0);
  assert.deepEqual(out, ['make target names ok (3 targets, 0 tools)']);
});

test('main refuses no Makefile, a package.json that does not parse, and bad arguments', () => {
  const none = capture();
  assert.equal(main([], { ...none.io, cwd: '/r', read: tree({}) }), 1);
  assert.deepEqual(none.err, ['make target names: no Makefile in /r']);
  const broken = capture();
  assert.equal(main([], { ...broken.io, cwd: '/r', read: tree({ Makefile: MAKEFILE, 'package.json': '{' }) }), 1);
  assert.match(broken.err[0], /^make target names: \/r\/package\.json is not valid JSON: /);
  const bad = capture();
  assert.equal(main(['--nope', 'x'], { ...bad.io, cwd: '/r', read: tree({}) }), 1);
  assert.deepEqual(bad.err, ['make target names: unexpected --nope x: pass --root DIR, --allow TARGET=REASON and --require-mise']);
});

test('--require-mise fails a repository with no .mise.toml, which otherwise reads as no tools', () => {
  const { out, err, io } = capture();
  assert.equal(main(['--require-mise'], { ...io, cwd: '/r', read: tree({ Makefile: MAKEFILE }) }), 1);
  assert.deepEqual(out, []);
  assert.deepEqual(err, ['make target names: --require-mise, and /r/.mise.toml is missing or pins no tool']);
});

test('--require-mise fails a .mise.toml that pins no tool', () => {
  const { err, io } = capture();
  assert.equal(main(['--require-mise'], { ...io, cwd: '/r', read: tree({ Makefile: MAKEFILE, '.mise.toml': '[env]\nA = "1"\n' }) }), 1);
  assert.deepEqual(err, ['make target names: --require-mise, and /r/.mise.toml is missing or pins no tool']);
});

test('--require-mise passes when .mise.toml pins tools, and still checks the targets', () => {
  const clean = capture();
  assert.equal(main(['--require-mise'], { ...clean.io, cwd: '/r', read: tree({ Makefile: MAKEFILE, '.mise.toml': MISE }) }), 0);
  assert.deepEqual(clean.out, ['make target names ok (3 targets, 1 tools)']);
  const named = capture();
  const read = tree({ Makefile: `${MAKEFILE}check-maestro: ## Flows\n\ttrue\n`, '.mise.toml': MISE });
  assert.equal(main(['--require-mise'], { ...named.io, cwd: '/r', read }), 1);
  assert.match(named.err[0], /^check-maestro \(maestro\) is named after a tool/);
});

test('as a command it reads the files of --root', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'make-target-names-'));
  roots.push(root);
  writeFileSync(path.join(root, 'Makefile'), 'check-shellcheck: ## Lint\n\ttrue\n');
  writeFileSync(path.join(root, '.mise.toml'), '[tools]\nshellcheck = "0.11.0"\n');
  const run = spawnSync(process.execPath, [SCRIPT, '--root', root], { encoding: 'utf8', env: process.env });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /^check-shellcheck \(shellcheck\) is named after a tool/m);
  writeFileSync(path.join(root, 'Makefile'), 'lint-scripts: ## Lint\n\ttrue\n');
  const ok = spawnSync(process.execPath, [SCRIPT, '--root', root], { encoding: 'utf8', env: process.env });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, 'make target names ok (1 targets, 1 tools)\n');
});
