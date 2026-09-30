import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

// lefthook itself (pinned in .mise.toml) prints the configuration it would
// run, `extends` applied: `lefthook dump`. So the comparison below is the real
// merge, not a model of it.
const PACKAGE = fileURLToPath(new URL('.', import.meta.url));
const FIXTURES = path.join(PACKAGE, 'fixtures', 'template', 'lefthook');
const scratch = mkdtempSync(path.join(tmpdir(), 'app-tooling-lefthook-'));
after(() => rmSync(scratch, { recursive: true, force: true }));

/** A git repository holding `config` as its lefthook.yml, this package installed. */
function repository(name, config) {
  const dir = path.join(scratch, name);
  mkdirSync(path.join(dir, 'node_modules', '@blinkbitcoin'), { recursive: true });
  symlinkSync(PACKAGE, path.join(dir, 'node_modules', '@blinkbitcoin', 'app-tooling'));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  if (typeof config === 'string') writeFileSync(path.join(dir, 'lefthook.yml'), config);
  else copyFileSync(config.file, path.join(dir, 'lefthook.yml'));
  return dir;
}

const dump = (dir) => JSON.parse(execFileSync('lefthook', ['dump', '--format', 'json'], { cwd: dir, encoding: 'utf8' }));

test("the template's future lefthook.yml runs today's hooks", () => {
  const today = dump(repository('today', { file: path.join(FIXTURES, 'today.yml') }));
  const { extends: extended, ...future } = dump(repository('future', { file: path.join(FIXTURES, 'future.yml') }));
  assert.deepEqual(extended, ['node_modules/@blinkbitcoin/app-tooling/expo/lefthook.yml']);
  assert.deepStrictEqual(future, today);
});

test("the shared file wins over an app's key, and an app can still add one or switch a command off", () => {
  const config = dump(
    repository(
      'override',
      [
        'extends:',
        '  - node_modules/@blinkbitcoin/app-tooling/expo/lefthook.yml',
        'pre-commit:',
        '  commands:',
        '    eslint:',
        "      glob: 'app/**'",
        '      skip: true',
        '',
      ].join('\n'),
    ),
  );
  const { eslint } = config['pre-commit'].commands;
  assert.deepEqual(eslint.glob, ['src/**/*.{ts,tsx}'], 'the shared glob wins');
  assert.equal(eslint.skip, true, "the app's skip is kept");
});
