import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main, parseArgs, rubyFiles } from './bin/check-release.mjs';

const BIN = fileURLToPath(new URL('./bin/check-release.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'check-release-'));
after(() => rmSync(work, { recursive: true, force: true }));
let n = 0;

/** A repository with a fastlane directory holding the given files (names relative to it). */
const repo = (files = {}, directory = 'fastlane') => {
  const root = path.join(work, `repo-${++n}`);
  for (const [name, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, directory, name)), { recursive: true });
    writeFileSync(path.join(root, directory, name), text);
  }
  mkdirSync(root, { recursive: true });
  return root;
};
const FULL = { Fastfile: '', 'lanes/b.rb': '', 'lanes/a.rb': '', 'lanes/readme.md': '', 'test/lanes_test.rb': '', 'test/helper.rb': '' };

const harness = ({ statuses = {}, skillsStatus = 0 } = {}) => {
  const out = { log: [], error: [], calls: [], skillsCalls: [] };
  return {
    out,
    options: (cwd) => ({
      cwd,
      log: (line) => out.log.push(line),
      error: (line) => out.error.push(line),
      run: (command, args, env) => {
        const key = [command, ...args].join(' ');
        out.calls.push(env.FASTLANE_SKIP_ENV_ASSERT ? `${key} [skip-env-assert]` : key);
        return statuses[key] ?? 0;
      },
      skills: (argv, options) => {
        out.skillsCalls.push([argv, options.cwd]);
        return skillsStatus;
      },
    }),
  };
};

test('parseArgs defaults to fastlane/, takes another directory, refuses anything else', () => {
  assert.deepEqual(parseArgs([]), { directory: 'fastlane' });
  assert.deepEqual(parseArgs(['--fastlane-directory', 'mobile/fastlane/']), { directory: 'mobile/fastlane' });
  assert.throws(() => parseArgs(['--fastlane-directory']), /unexpected --fastlane-directory: pass --fastlane-directory DIR/);
  assert.throws(() => parseArgs(['--nope', 'x']), /unexpected --nope x/);
});

test('rubyFiles lists the Fastfile, then each lane, then each test, in name order, ruby files only', () => {
  assert.deepEqual(rubyFiles(repo(FULL), 'fastlane'), [
    'fastlane/Fastfile',
    'fastlane/lanes/a.rb',
    'fastlane/lanes/b.rb',
    'fastlane/test/helper.rb',
    'fastlane/test/lanes_test.rb',
  ]);
  assert.deepEqual(rubyFiles(repo({ Fastfile: '' }), 'fastlane'), ['fastlane/Fastfile']);
});

test('every step runs in order, and check-skills last', () => {
  const { out, options } = harness();
  assert.equal(main([], options(repo(FULL))), 0);
  assert.deepEqual(out.calls, [
    'bundle check',
    'ruby -c fastlane/Fastfile',
    'ruby -c fastlane/lanes/a.rb',
    'ruby -c fastlane/lanes/b.rb',
    'ruby -c fastlane/test/helper.rb',
    'ruby -c fastlane/test/lanes_test.rb',
    'bundle exec fastlane lanes [skip-env-assert]',
    'bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb',
  ]);
  assert.equal(out.skillsCalls.length, 1);
  assert.equal(out.log.at(-1), 'release checks ok');
});

test('another fastlane directory is read and named', () => {
  const { out, options } = harness();
  const root = repo({ Fastfile: '', 'test/lanes_test.rb': '' }, 'app/fastlane');
  assert.equal(main(['--fastlane-directory', 'app/fastlane'], options(root)), 0);
  assert.ok(out.calls.includes('bundle exec ruby -Iapp/fastlane/test app/fastlane/test/lanes_test.rb'), out.calls.join('\n'));
});

test('without the lane tests it still lists the lanes and runs the skills', () => {
  const { out, options } = harness();
  assert.equal(main([], options(repo({ Fastfile: '' }))), 0);
  assert.ok(!out.calls.some((call) => call.startsWith('bundle exec ruby')));
  assert.equal(out.skillsCalls.length, 1);
});

test('gems that are not installed say how to install them, and nothing else runs', () => {
  const { out, options } = harness({ statuses: { 'bundle check': 1 } });
  assert.equal(main([], options(repo(FULL))), 1);
  assert.deepEqual(out.calls, ['bundle check']);
  assert.match(out.error[0], /the gems are not installed - run: install-gems/);
});

test('a Ruby syntax error stops the run with its status', () => {
  const { out, options } = harness({ statuses: { 'ruby -c fastlane/lanes/a.rb': 1 } });
  assert.equal(main([], options(repo(FULL))), 1);
  assert.ok(!out.calls.some((call) => call.includes('fastlane lanes')));
  assert.deepEqual(out.error, ['check-release: ruby -c fastlane/lanes/a.rb failed (exit 1)']);
});

test('lanes that fastlane cannot list stop the run', () => {
  const { out, options } = harness({ statuses: { 'bundle exec fastlane lanes': 4 } });
  assert.equal(main([], options(repo(FULL))), 4);
  assert.ok(!out.calls.some((call) => call.startsWith('bundle exec ruby')));
});

test('failing lane tests stop the run before the skills', () => {
  const { out, options } = harness({ statuses: { 'bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb': 2 } });
  assert.equal(main([], options(repo(FULL))), 2);
  assert.equal(out.skillsCalls.length, 0);
});

test('failing skills end the run with their status', () => {
  const { out, options } = harness({ skillsStatus: 7 });
  assert.equal(main([], options(repo(FULL))), 7);
  assert.notEqual(out.log.at(-1), 'release checks ok');
});

test('a bad argument is refused with the usage', () => {
  const { out, options } = harness();
  assert.equal(main(['--nope'], options(repo())), 1);
  assert.match(out.error[0], /^check-release: unexpected --nope: pass --fastlane-directory DIR$/);
  assert.deepEqual(out.calls, []);
});

test('as a command it runs bundle and ruby from the repository, FASTLANE_SKIP_ENV_ASSERT set only for the lane list', () => {
  const root = repo({ Fastfile: '', 'test/lanes_test.rb': '' });
  const bin = path.join(work, `bin-${n}`);
  const log = path.join(work, `calls-${n}.log`);
  mkdirSync(bin);
  for (const tool of ['bundle', 'ruby']) {
    writeFileSync(path.join(bin, tool), `#!/bin/sh\necho "${tool} $* skip=$FASTLANE_SKIP_ENV_ASSERT" >> "${log}"\n`);
    chmodSync(path.join(bin, tool), 0o755);
  }
  const child = spawnSync(process.execPath, [BIN], { cwd: root, encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, FASTLANE_SKIP_ENV_ASSERT: '' } });
  assert.equal(child.status, 0, child.stderr);
  const calls = readFileSync(log, 'utf8').trim().split('\n');
  assert.deepEqual(calls, [
    'bundle check skip=',
    'ruby -c fastlane/Fastfile skip=',
    'ruby -c fastlane/test/lanes_test.rb skip=',
    'bundle exec fastlane lanes skip=1',
    'bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb skip=',
  ]);
  assert.match(child.stdout, /release checks ok/);
});

test('as a command a tool that cannot start fails the step', () => {
  const root = repo({ Fastfile: '' });
  const child = spawnSync(process.execPath, [BIN], { cwd: root, encoding: 'utf8', env: { ...process.env, PATH: path.join(work, 'empty') } });
  assert.equal(child.status, 1);
  assert.match(child.stderr, /the gems are not installed/);
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line), run: () => assert.fail('--help ran something') });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +check-release(?: |$)/m);
  assert.deepEqual(err, []);
});
