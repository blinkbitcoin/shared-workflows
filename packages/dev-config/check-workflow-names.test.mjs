import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { displayName, main, parseArgs, problems } from './bin/check-workflow-names.mjs';

const SCRIPT = fileURLToPath(new URL('./bin/check-workflow-names.mjs', import.meta.url));
const roots = [];
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

const TEMPLATE = [
  { prefix: 'ci', display: 'CI' },
  { prefix: 'cd', display: 'CD' },
];
const wf = (file, name) => ({ file, text: name === null ? 'on: push\n' : `name: ${name}\non: push\n` });

test('the display name is the top-level name:, unquoted, or null', () => {
  assert.equal(displayName('name: "CI / Web"\non: push\n'), 'CI / Web');
  assert.equal(displayName("name: 'CD'\n"), 'CD');
  assert.equal(displayName('on: push\njobs:\n  a:\n    name: Job\n'), null);
});

test('groups and a root are read from the arguments; anything else is refused', () => {
  assert.deepEqual(parseArgs(['--group', 'ci=CI', '--group', 'check', '--root', 'app'], '/r'), {
    root: '/r/app',
    groups: [
      { prefix: 'ci', display: 'CI' },
      { prefix: 'check', display: null },
    ],
  });
  assert.throws(() => parseArgs([], '/r'), /name at least one --group/);
  assert.throws(() => parseArgs(['--group', 'CI='], '/r'), /unexpected --group CI=/);
  assert.throws(() => parseArgs(['--group'], '/r'), /unexpected --group:/);
  assert.throws(() => parseArgs(['--root'], '/r'), /unexpected --root:/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/r'), /unexpected --nope x/);
});

test("the template's files and display names fit its groups", () => {
  assert.deepEqual(
    problems([wf('ci.yml', 'CI'), wf('ci-web.yml', 'CI / Web'), wf('cd-beta.yml', "'CD / Beta'")], TEMPLATE),
    [],
  );
});

test('a file outside every group, a .yaml spelling and a bare prefix with no slug are named', () => {
  assert.deepEqual(problems([wf('release.yml', 'Release'), wf('ci-web.yaml', 'CI / Web'), wf('ci-.yml', 'CI / x')], TEMPLATE), [
    'release.yml is in no group: name it ci-*.yml or cd-*.yml, spelled .yml',
    'ci-web.yaml is in no group: name it ci-*.yml or cd-*.yml, spelled .yml',
    'ci-.yml is in no group: name it ci-*.yml or cd-*.yml, spelled .yml',
  ]);
});

test('a display name that does not match its prefix is named, with what it should be', () => {
  assert.deepEqual(
    problems([wf('ci.yml', 'Checks'), wf('ci-web.yml', 'Web'), wf('cd-beta.yml', 'CD /'), wf('cd-x.yml', null)], TEMPLATE),
    [
      'ci.yml displays as "Checks", not "CI"',
      'ci-web.yml displays as "Web", not "CI / ..."',
      'cd-beta.yml displays as "CD /", not "CD / ..."',
      'cd-x.yml displays as nothing (no top-level name:), not "CD / ..."',
    ],
  );
});

test('a group without a display name requires only the prefix', () => {
  assert.deepEqual(problems([wf('check-code.yml', 'Checks'), wf('check.yml', null)], [{ prefix: 'check', display: null }]), []);
});

const capture = () => {
  const out = [];
  const err = [];
  return { out, err, io: { log: (l) => out.push(l), error: (l) => err.push(l) } };
};

test('main reports every problem, an empty directory, one that cannot be read, and bad arguments', () => {
  const bad = capture();
  assert.equal(main(['--group', 'ci=CI'], { ...bad.io, cwd: '/r', read: () => [wf('x.yml', 'X')] }), 1);
  assert.deepEqual(bad.err, ['x.yml is in no group: name it ci-*.yml, spelled .yml', "workflow names: 1 workflow(s) outside their group's naming"]);
  const empty = capture();
  assert.equal(main(['--group', 'ci'], { ...empty.io, cwd: '/r', read: () => [] }), 1);
  assert.deepEqual(empty.err, ['workflow names: no workflow file in /r/.github/workflows']);
  const unreadable = capture();
  const read = () => {
    throw new Error('ENOENT');
  };
  assert.equal(main(['--group', 'ci'], { ...unreadable.io, cwd: '/r', read }), 1);
  assert.deepEqual(unreadable.err, ['workflow names: could not read /r/.github/workflows: ENOENT']);
  const args = capture();
  assert.equal(main([], { ...args.io, cwd: '/r' }), 1);
  assert.deepEqual(args.err, ['workflow names: name at least one --group']);
});

test('as a command it reads the workflows of --root', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'workflow-names-'));
  roots.push(root);
  mkdirSync(path.join(root, '.github/workflows'), { recursive: true });
  writeFileSync(path.join(root, '.github/workflows/ci.yml'), 'name: CI\n');
  writeFileSync(path.join(root, '.github/workflows/cd-beta.yml'), 'name: CD / Beta\n');
  const run = (...groups) =>
    spawnSync(process.execPath, [SCRIPT, '--root', root, ...groups.flatMap((g) => ['--group', g])], {
      encoding: 'utf8',
      env: process.env,
    });
  const ok = run('ci=CI', 'cd=CD');
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, 'workflow names ok (2 workflows)\n');
  const wrong = run('ci=CI');
  assert.equal(wrong.status, 1);
  assert.match(wrong.stderr, /^cd-beta\.yml is in no group/m);
});
