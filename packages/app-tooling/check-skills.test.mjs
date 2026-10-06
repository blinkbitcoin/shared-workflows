import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { findSkillSuites, main, parseArgs } from './bin/check-skills.mjs';

const BIN = fileURLToPath(new URL('./bin/check-skills.mjs', import.meta.url));

/** A throwaway repository; `skills` maps a skill name to its run.sh body, or null for a skill without tests. */
const repository = (t, skills = {}) => {
  const root = mkdtempSync(path.join(tmpdir(), 'check-skills-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const [name, body] of Object.entries(skills)) {
    const dir = path.join(root, '.claude/skills', name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, 'SKILL.md'), `# ${name}\n`);
    if (body !== null) {
      mkdirSync(path.join(dir, 'tests'));
      writeFileSync(path.join(dir, 'tests/run.sh'), body);
    }
  }
  return root;
};

/** Captures what `main` writes, and records each suite it runs instead of running it. */
const capture = (root, statuses = {}, argv = ['--root', root]) => {
  const out = [];
  const err = [];
  const ran = [];
  const code = main(argv, {
    cwd: '/elsewhere',
    run: (suite, where) => {
      ran.push([suite, where]);
      return statuses[suite] ?? 0;
    },
    log: (line) => out.push(line),
    error: (line) => err.push(line),
  });
  return { code, out, err, ran };
};

test('a repository without a skills directory has no suites', (t) => {
  assert.deepEqual(findSkillSuites(repository(t)), []);
});

test('finds each skill that has a tests/run.sh, in name order, and skips the rest', (t) => {
  const root = repository(t, { zeta: '', alpha: '', 'no-tests': null });
  writeFileSync(path.join(root, '.claude/skills/README.md'), 'not a skill\n');
  assert.deepEqual(findSkillSuites(root), ['.claude/skills/alpha/tests/run.sh', '.claude/skills/zeta/tests/run.sh']);
});

test('parseArgs takes --root against the working directory, and refuses anything else', () => {
  assert.deepEqual(parseArgs([], '/w'), { root: '/w' });
  assert.deepEqual(parseArgs(['--root', 'app'], '/w'), { root: path.resolve('/w', 'app') });
  assert.throws(() => parseArgs(['--root'], '/w'), /unexpected --root: pass --root DIR/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/w'), /unexpected --nope x: pass --root DIR/);
});

test('main passes with nothing to run, saying where it looked', (t) => {
  const { code, out, err, ran } = capture(repository(t, { 'no-tests': null }));
  assert.deepEqual({ code, out, err, ran }, {
    code: 0,
    out: ['skills: no skill under .claude/skills/ has a tests/run.sh'],
    err: [],
    ran: [],
  });
});

test('main runs every suite from the root, each under a header, and counts them', (t) => {
  const root = repository(t, { beta: '', alpha: '' });
  const { code, out, err, ran } = capture(root);
  assert.equal(code, 0);
  assert.deepEqual(ran, [
    ['.claude/skills/alpha/tests/run.sh', root],
    ['.claude/skills/beta/tests/run.sh', root],
  ]);
  assert.deepEqual(out, ['== .claude/skills/alpha/tests/run.sh', '== .claude/skills/beta/tests/run.sh', 'skills ok (2 suites)']);
  assert.deepEqual(err, []);
});

test('one suite is counted in the singular', (t) => {
  assert.equal(capture(repository(t, { alpha: '' })).out.at(-1), 'skills ok (1 suite)');
});

test('main stops at the first failing suite and exits with its status', (t) => {
  const root = repository(t, { alpha: '', beta: '', gamma: '' });
  const { code, out, err, ran } = capture(root, { '.claude/skills/beta/tests/run.sh': 3 });
  assert.equal(code, 3);
  assert.deepEqual(
    ran.map(([suite]) => suite),
    ['.claude/skills/alpha/tests/run.sh', '.claude/skills/beta/tests/run.sh'],
  );
  assert.deepEqual(out, ['== .claude/skills/alpha/tests/run.sh', '== .claude/skills/beta/tests/run.sh']);
  assert.deepEqual(err, ['skills: .claude/skills/beta/tests/run.sh failed (exit 3)']);
});

test('main reads the working directory without --root, and refuses a bad argument', (t) => {
  const root = repository(t, { alpha: '' });
  const out = [];
  assert.equal(main([], { cwd: root, run: () => 0, log: (line) => out.push(line), error: () => {} }), 0);
  assert.equal(out[0], '== .claude/skills/alpha/tests/run.sh');
  const bad = capture(root, {}, ['--nope']);
  assert.deepEqual(bad, { code: 1, out: [], err: ['skills: unexpected --nope: pass --root DIR'], ran: [] });
});

test('as a command it runs each suite with bash, from the root', (t) => {
  const root = repository(t, {
    alpha: 'pwd > alpha.ran\n',
    beta: 'echo "beta says hello"\n',
  });
  const result = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(path.join(root, 'alpha.ran'), 'utf8').trim(), realpathSync(root));
  assert.match(result.stdout, /== \.claude\/skills\/alpha\/tests\/run\.sh\n== \.claude\/skills\/beta\/tests\/run\.sh\nbeta says hello\nskills ok \(2 suites\)\n$/);
});

test('as a command it fails with the status of a failing suite', (t) => {
  const root = repository(t, { alpha: 'exit 4\n' });
  const result = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(result.status, 4);
  assert.equal(result.stderr, 'skills: .claude/skills/alpha/tests/run.sh failed (exit 4)\n');
});

test('as a command a suite killed by a signal is a failure, not a pass', (t) => {
  const root = repository(t, { alpha: 'kill -9 $$\n' });
  const result = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stderr, 'skills: .claude/skills/alpha/tests/run.sh failed (exit 1)\n');
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line), run: () => assert.fail('--help ran something') });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +check-skills(?: |$)/m);
  assert.deepEqual(err, []);
});
