// scripts/self/render-contract-table.mjs: the program that generates the
// requirement table in docs/adopting-an-existing-repo.md from
// packages/dev-config/contract.json.
//
// Covered here: how each requirement's "You need" and "What" cells read (every
// severity and toggle shape, every target kind, one, two and three targets),
// the table itself (a profile with no rows, a profile with no title), the
// splice between the two markers and its refusal when either is gone, and the
// program run as a program - printing the page, rewriting it with --write, and
// saying so when there was nothing to rewrite - and imported, when it runs
// nothing.
//
// --write rewrites the real adoption doc, and the script takes no path to
// write elsewhere. The --write cases therefore preload a module that sends the
// program's reads and writes of that one path to a temporary copy, so the real
// file is never written. Whether the real doc is up to date is
// test/contract-doctor.bats' question, not this file's.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  END,
  PROFILE_TITLE,
  START,
  need,
  renderTable,
  splice,
  targetOf,
} from '../scripts/self/render-contract-table.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts/self/render-contract-table.mjs');
const DOC = path.join(ROOT, 'docs/adopting-an-existing-repo.md');
const CONTRACT = JSON.parse(readFileSync(path.join(ROOT, 'packages/dev-config/contract.json'), 'utf8'));

const scratch = mkdtempSync(path.join(tmpdir(), 'render-contract-table-'));
after(() => rmSync(scratch, { recursive: true, force: true }));

// Redirects the program's reads and writes of the real adoption doc to a copy.
// Replacing the functions on the CommonJS `fs` object and then syncing the
// built-in ES module exports is what makes the program's own
// `import { readFileSync, writeFileSync } from 'node:fs'` see the replacements.
const PRELOAD = path.join(scratch, 'redirect-doc.mjs');
writeFileSync(
  PRELOAD,
  `import fs from 'node:fs';
import path from 'node:path';
import { syncBuiltinESMExports } from 'node:module';
const real = path.resolve(process.env.RENDER_TEST_REAL_DOC);
const copy = process.env.RENDER_TEST_COPY_DOC;
const { readFileSync, writeFileSync } = fs;
const target = (file) => (typeof file === 'string' && path.resolve(file) === real ? copy : file);
fs.readFileSync = (file, ...rest) => readFileSync(target(file), ...rest);
fs.writeFileSync = (file, ...rest) => {
  if (target(file) !== copy) throw new Error('the program wrote a file other than the adoption doc: ' + file);
  return writeFileSync(copy, ...rest);
};
syncBuiltinESMExports();
`,
);

// Runs the program as a program. The environment spreads process.env so the
// coverage directory the test runner sets reaches the child.
function runProgram(argv, { copy } = {}) {
  const preload = copy ? ['--import', PRELOAD] : [];
  return spawnSync(process.execPath, [...preload, SCRIPT, ...argv], {
    encoding: 'utf8',
    env: { ...process.env, RENDER_TEST_REAL_DOC: DOC, RENDER_TEST_COPY_DOC: copy ?? '' },
  });
}

// --- the cells -------------------------------------------------------------

test('a requirement with a fallback reads as optional', () => {
  assert.equal(need({ severity: 'degrades' }), 'optional — a fallback runs');
});

test('a default-on toggle reads as required, with the input that turns it off', () => {
  assert.equal(
    need({ severity: 'required', toggle: 'check-code.yml:typecheck', defaultOn: true }),
    'required, or pass `typecheck: false`',
  );
});

test('a default-off toggle reads as needed only once it is turned on', () => {
  assert.equal(
    need({ severity: 'required', toggle: 'check-unit.yml:coverage', defaultOn: false }),
    'only if you set `coverage: true`',
  );
});

test('a requirement with no toggle and no fallback reads as required', () => {
  assert.equal(need({ severity: 'required', toggle: null }), 'required');
});

test('one target reads as itself, whether or not it came as a list', () => {
  assert.equal(targetOf({ kind: 'package-script', target: 'typecheck' }), '`typecheck`');
  assert.equal(targetOf({ kind: 'package-script', target: ['typecheck'] }), '`typecheck`');
});

test('two files are alternatives, joined with or', () => {
  assert.equal(targetOf({ kind: 'file', target: ['app.config.ts', 'app.json'] }), '`app.config.ts` or `app.json`');
});

test('three files are a comma list ending in or', () => {
  assert.equal(
    targetOf({ kind: 'file', target: ['a.json', 'b.json', 'c.json'] }),
    '`a.json`, `b.json` or `c.json`',
  );
});

test('the tools a mise configuration pins are all needed, joined with and', () => {
  assert.equal(targetOf({ kind: 'mise-tool', target: ['node', 'pnpm'] }), '`node` and `pnpm` in your mise config');
});

test('fastlane lanes read as lanes, three of them in a comma list ending in and', () => {
  assert.equal(
    targetOf({ kind: 'fastlane-lane', target: ['build_ios', 'build_android', 'publish'] }),
    'the `build_ios`, `build_android` and `publish` lanes',
  );
});

test('the two make ci rules read as sentences, not as their targets', () => {
  assert.equal(
    targetOf({ kind: 'make-ci-reaches-ci', target: 'Makefile' }),
    'every gate CI runs, reachable from `make ci`',
  );
  assert.equal(targetOf({ kind: 'ci-runs-make-ci', target: 'Makefile' }), 'every gate `make ci` runs, run by CI');
});

test('an environment subset names its prefix and the names the lanes may read', () => {
  assert.equal(
    targetOf({ kind: 'fastlane-env-subset', prefix: 'APP_REVIEW_', target: ['APP_REVIEW_EMAIL', 'APP_REVIEW_NOTES'] }),
    'lanes that read only these `APP_REVIEW_*` names: `APP_REVIEW_EMAIL` and `APP_REVIEW_NOTES`',
  );
});

// --- the table -------------------------------------------------------------

test('each profile with requirements gets a titled section, one row per requirement', () => {
  const table = renderTable({
    profiles: ['checks', 'unit'],
    requirements: [
      { profile: 'checks', kind: 'package-script', target: 'lint', severity: 'required', toggle: null, neededBy: 'the lint job' },
      { profile: 'checks', kind: 'file', target: 'pnpm-lock.yaml', severity: 'degrades', neededBy: 'the install' },
    ],
  });
  assert.equal(
    table,
    [
      '',
      `### If you call ${PROFILE_TITLE.checks}`,
      '',
      '| What | You need | Why |',
      '| --- | --- | --- |',
      '| `lint` | required | the lint job |',
      '| `pnpm-lock.yaml` | optional — a fallback runs | the install |',
    ].join('\n'),
  );
});

test('a profile with no requirements gets no section at all', () => {
  const table = renderTable({ profiles: ['unit'], requirements: [] });
  assert.equal(table, '');
});

test('a profile with no title is headed by its own name', () => {
  const table = renderTable({
    profiles: ['nightly'],
    requirements: [{ profile: 'nightly', kind: 'package-script', target: 'soak', severity: 'required', neededBy: 'soak' }],
  });
  assert.match(table, /^### If you call nightly$/m);
});

test('every profile in the real contract has a title', () => {
  const untitled = CONTRACT.profiles.filter((profile) => !(profile in PROFILE_TITLE));
  assert.deepEqual(untitled, []);
});

// --- the splice ------------------------------------------------------------

test('the splice replaces what is between the markers and keeps the rest', () => {
  const text = `before\n${START}\nstale table\n${END}\nafter\n`;
  assert.equal(splice(text, 'new table'), `before\n${START}\nnew table\n\n${END}\nafter\n`);
});

test('a doc that lost its start marker is refused with an annotation', () => {
  assert.throws(() => splice(`no start\n${END}\n`, 'table'), {
    message: `::error::the adoption doc has lost its ${START} / ${END} markers`,
  });
});

test('a doc that lost its end marker is refused with an annotation', () => {
  assert.throws(() => splice(`${START}\nno end\n`, 'table'), { message: /^::error::the adoption doc has lost/ });
});

// --- the program -----------------------------------------------------------

test('run with no argument, it prints the doc with the table regenerated and writes nothing', () => {
  const before = readFileSync(DOC, 'utf8');
  const result = runProgram([]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, splice(before, renderTable(CONTRACT)));
  assert.equal(readFileSync(DOC, 'utf8'), before, 'the real adoption doc changed');
});

test('--write rewrites a stale doc and says it did', () => {
  const real = readFileSync(DOC, 'utf8');
  const copy = path.join(scratch, 'stale.md');
  writeFileSync(copy, `# Adopting\n\n${START}\nan old table\n${END}\n\nthe rest\n`);
  const result = runProgram(['--write'], { copy });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'adoption doc rewritten\n');
  assert.equal(readFileSync(copy, 'utf8'), `# Adopting\n\n${START}\n${renderTable(CONTRACT)}\n\n${END}\n\nthe rest\n`);
  assert.equal(readFileSync(DOC, 'utf8'), real, 'the real adoption doc was written');
});

test('--write on a doc that is already current says there was nothing to do', () => {
  const real = readFileSync(DOC, 'utf8');
  const copy = path.join(scratch, 'current.md');
  const current = `intro\n${START}\n${renderTable(CONTRACT)}\n\n${END}\n`;
  writeFileSync(copy, current);
  const result = runProgram(['--write'], { copy });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'adoption doc already up to date\n');
  assert.equal(readFileSync(copy, 'utf8'), current);
  assert.equal(readFileSync(DOC, 'utf8'), real, 'the real adoption doc was written');
});

test('a doc without its markers fails the program with the annotation', () => {
  const copy = path.join(scratch, 'no-markers.md');
  writeFileSync(copy, 'a page someone rewrote by hand\n');
  const result = runProgram(['--write'], { copy });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /::error::the adoption doc has lost its/);
  assert.equal(readFileSync(copy, 'utf8'), 'a page someone rewrote by hand\n');
});

test('imported rather than run, it renders and writes nothing', () => {
  // `node --input-type=module -e` has no script argument at all, which is the
  // other half of the am-I-the-program guard.
  const result = spawnSync(
    process.execPath,
    ['--input-type=module', '-e', `await import(${JSON.stringify(SCRIPT)}); process.stdout.write('imported');`],
    { encoding: 'utf8', env: { ...process.env } },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'imported');
});
