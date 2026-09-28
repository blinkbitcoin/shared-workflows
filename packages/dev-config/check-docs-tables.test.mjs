import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  DOC_EXCLUDES,
  DOC_GLOBS,
  docFiles,
  fencedBlocks,
  formatFindings,
  MAX_LINE,
  main,
  overlongTableLines,
  parseArgs,
} from './bin/check-docs-tables.mjs';

const row = (cell) => `| a | ${cell} |`;
const table = (cell) => ['| h | h |', '| --- | --- |', row(cell)].join('\n');

test('a cell within the limit is not a finding', () => {
  assert.deepEqual(overlongTableLines(table('x'.repeat(MAX_LINE))), []);
});

test('a cell one character over the limit is a finding, with line and column', () => {
  const findings = overlongTableLines(table('x'.repeat(MAX_LINE + 1)));
  assert.equal(findings.length, 1);
  assert.deepEqual(
    { line: findings[0].line, column: findings[0].column, width: findings[0].width },
    { line: 3, column: 2, width: MAX_LINE + 1 },
  );
});

test('<br> segments are measured individually, not as one cell', () => {
  const half = 'x'.repeat(MAX_LINE);
  assert.deepEqual(overlongTableLines(table(`${half}<br>${half}`)), []);
  assert.equal(overlongTableLines(table(`${half}<br>${half}x`)).length, 1);
});

test('<br/> and <BR /> split the same way', () => {
  const half = 'x'.repeat(MAX_LINE);
  assert.deepEqual(overlongTableLines(table(`${half}<br/>${half}`)), []);
  assert.deepEqual(overlongTableLines(table(`${half}<BR />${half}`)), []);
});

test('markdown decoration does not count towards the visible width', () => {
  const text = 'x'.repeat(MAX_LINE);
  assert.deepEqual(overlongTableLines(table(`\`${text}\``)), []);
  assert.deepEqual(overlongTableLines(table(`**${text}**`)), []);
  assert.deepEqual(overlongTableLines(table(`[${text}](https://example.com/a/very/long/url)`)), []);
  assert.deepEqual(overlongTableLines(table(`<kbd>${text}</kbd>`)), []);
  assert.deepEqual(overlongTableLines(table(`${'x'.repeat(MAX_LINE)}&nbsp;`)), []);
});

test('an escaped pipe stays inside its cell rather than starting a new one', () => {
  const findings = overlongTableLines(table(`a \\| b ${'x'.repeat(MAX_LINE)}`));
  assert.equal(findings.length, 1);
  assert.equal(findings[0].column, 2);
});

test('the separator row is never measured', () => {
  const wide = `| ${'-'.repeat(MAX_LINE + 10)} | --- |`;
  assert.deepEqual(overlongTableLines(['| h | h |', wide].join('\n')), []);
});

test('a table-shaped line inside a fenced block is ignored', () => {
  const markdown = ['```', table('x'.repeat(MAX_LINE + 50)), '```'].join('\n');
  assert.deepEqual(overlongTableLines(markdown), []);
});

test('a table after a closed fence is measured again', () => {
  const markdown = ['```', '| ignored |', '```', table('x'.repeat(MAX_LINE + 1))].join('\n');
  assert.equal(overlongTableLines(markdown).length, 1);
});

test('a non-table line is never measured', () => {
  assert.deepEqual(overlongTableLines('x'.repeat(MAX_LINE + 100)), []);
});

test('the limit is configurable, which is how the 72/120 measurement was taken', () => {
  assert.equal(overlongTableLines(table('x'.repeat(80)), 72).length, 1);
  assert.deepEqual(overlongTableLines(table('x'.repeat(80)), 120), []);
});

test('a finding formats to a file:line with the column, the width and the fix', () => {
  const [line] = formatFindings('docs/x.md', overlongTableLines(table('x'.repeat(MAX_LINE + 1))));
  assert.match(line, /^docs\/x\.md:3: table cell \(column 2\)/);
  assert.match(line, new RegExp(`${MAX_LINE + 1}-character line, limit ${MAX_LINE}`));
  assert.match(line, /break it with <br>/);
});

test('the doc set covers the published docs and excludes the agent plans', () => {
  assert.ok(DOC_GLOBS.includes('README.md'));
  assert.ok(DOC_GLOBS.includes('docs/**/*.md'));
  assert.deepEqual(DOC_EXCLUDES, ['docs/superpowers/']);
});

// M3: the table check used to toggle a boolean on any ```-prefixed line, so a
// tilde fence was invisible and a four-backtick block containing a three-
// backtick line desynced the scanner - measuring code as a table, then skipping
// the rest of the file. Both checks now share fencedBlocks().
test('a tilde-fenced block is skipped like a backtick-fenced one', () => {
  const markdown = ['~~~', table('x'.repeat(MAX_LINE + 50)), '~~~'].join('\n');
  assert.deepEqual(overlongTableLines(markdown), []);
});

test('a three-backtick line inside a four-backtick fence does not desync the scan', () => {
  const markdown = [
    '````markdown',
    table('x'.repeat(MAX_LINE + 50)), // inside the outer fence: not measured
    '```',
    table('y'.repeat(MAX_LINE + 50)), // still inside it
    '````',
    table('z'.repeat(MAX_LINE + 1)), // after it: measured
  ].join('\n');
  const findings = overlongTableLines(markdown);
  assert.equal(findings.length, 1);
  assert.match(findings[0].text, /^z+$/);
});

test('an unclosed fence swallows the rest of the file rather than half of it', () => {
  const markdown = ['```', table('x'.repeat(MAX_LINE + 50))].join('\n');
  assert.deepEqual(overlongTableLines(markdown), []);
});

test('fencedBlocks reports the info string, the delimiters and whether it closed', () => {
  const [block] = fencedBlocks(['```ts title=x', 'const a = 1;', '```']);
  assert.deepEqual(
    { info: block.info, start: block.start, end: block.end, closed: block.closed },
    { info: 'ts', start: 0, end: 2, closed: true },
  );
  assert.deepEqual(block.body, ['const a = 1;']);
});

test('fencedBlocks reports an unclosed fence as running to the end of the file', () => {
  const [block] = fencedBlocks(['```ts', 'const a = 1;']);
  assert.deepEqual({ end: block.end, closed: block.closed }, { end: 2, closed: false });
});

const SCRIPT = fileURLToPath(new URL('./bin/check-docs-tables.mjs', import.meta.url));

/** Captures what `main` writes, instead of letting it reach the test output. */
const capture = () => {
  const out = [];
  const err = [];
  return { out, err, io: { log: (line) => out.push(line), error: (line) => err.push(line) } };
};

test('docFiles globs the doc set, sorted, without the excluded subtrees', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'docs-tables-'));
  try {
    mkdirSync(path.join(dir, 'docs/plans'), { recursive: true });
    for (const file of ['b.md', 'a.md', 'docs/plans/skip.md', 'docs/keep.md', 'notes.txt']) {
      writeFileSync(path.join(dir, file), '');
    }
    assert.deepEqual(docFiles([`${dir}/*.md`, `${dir}/docs/**/*.md`], [`${dir}/docs/plans/`]), [
      `${dir}/a.md`,
      `${dir}/b.md`,
      `${dir}/docs/keep.md`,
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('main passes the named files that stay within the limit', () => {
  const { out, err, io } = capture();
  const read = () => table('x');
  assert.equal(main(['a.md', 'b.md'], { ...io, read }), 0);
  assert.deepEqual(out, ['docs tables ok (2 files)']);
  assert.deepEqual(err, []);
});

test('main reports every over-wide line and exits 1', () => {
  const { out, err, io } = capture();
  const read = (file) => (file === 'wide.md' ? table('x'.repeat(MAX_LINE + 1)) : table('x'));
  assert.equal(main(['ok.md', 'wide.md'], { ...io, read }), 1);
  assert.deepEqual(out, []);
  assert.equal(err.length, 2);
  assert.match(err[0], /^wide\.md:3: table cell \(column 2\)/);
  assert.equal(err[1], `docs tables: 1 over-wide table line(s), limit ${MAX_LINE}`);
});

test('main with no files checks the whole doc set', () => {
  const { out, io } = capture();
  const code = main([], { ...io, read: () => '', listDocs: () => ['README.md', 'AGENTS.md'] });
  assert.equal(code, 0);
  assert.deepEqual(out, ['docs tables ok (2 files)']);
});

// The command line, end to end, in a scratch directory holding a doc set of its
// own. The environment is inherited so a coverage run sees the child too.
test('as a command it checks the doc set of the working directory', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'docs-tables-cli-'));
  try {
    writeFileSync(path.join(dir, 'README.md'), table('x'));
    const run = (args) =>
      spawnSync(process.execPath, [SCRIPT, ...args], {
        cwd: dir,
        encoding: 'utf8',
        env: process.env,
      });
    const ok = run([]);
    assert.equal(ok.status, 0, ok.stderr);
    assert.equal(ok.stdout, 'docs tables ok (1 files)\n');

    writeFileSync(path.join(dir, 'wide.md'), table('x'.repeat(MAX_LINE + 1)));
    const wide = run(['wide.md']);
    assert.equal(wide.status, 1);
    assert.match(wide.stderr, /over-wide table line/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('--max sets the limit for the whole run, and a bad value is refused', () => {
  assert.deepEqual(parseArgs(['--max', '72', 'a.md']), { max: 72, files: ['a.md'] });
  assert.deepEqual(parseArgs([]), { max: MAX_LINE, files: [] });
  const { out, err, io } = capture();
  assert.equal(main(['--max', '72', 'a.md'], { ...io, read: () => table('x'.repeat(80)) }), 1);
  assert.deepEqual(out, []);
  assert.match(err[0], /80-character line, limit 72/);
  assert.equal(err[1], 'docs tables: 1 over-wide table line(s), limit 72');
  const bad = capture();
  assert.equal(main(['--max', 'wide'], { ...bad.io, read: () => '' }), 1);
  assert.deepEqual(bad.err, ['docs tables: --max needs a positive whole number, got wide']);
});

test('docFiles takes a plain file, a directory of the cwd and a missing directory', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'docs-tables-'));
  const cwd = process.cwd();
  try {
    writeFileSync(path.join(dir, 'README.md'), '');
    mkdirSync(path.join(dir, 'README.md.d'));
    process.chdir(dir);
    assert.deepEqual(docFiles(['README.md', 'absent.md', '*.md', 'nope/**/*.md', 'README.md.d']), ['README.md']);
  } finally {
    process.chdir(cwd);
    rmSync(dir, { recursive: true, force: true });
  }
});
