import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  BROWSER_PATHS,
  changedDocs,
  checkBlock,
  cleanOutput,
  extractMermaidBlocks,
  filesWithMermaid,
  findBrowser,
  formatParseError,
  MERMAID_CLI,
  main,
  mmdcRunner,
  PROBE_DIAGRAM,
  probeToolchain,
  writePuppeteerConfig,
} from './bin/check-diagrams.mjs';

const doc = (...lines) => lines.join('\n');

test('extracts a mermaid block with the line of its opening fence', () => {
  const markdown = doc('# Title', '', '```mermaid', 'graph TD;', '  A-->B;', '```', 'after');
  assert.deepEqual(extractMermaidBlocks(markdown), [{ line: 3, code: 'graph TD;\n  A-->B;' }]);
});

test('ignores fences of other languages', () => {
  const markdown = doc('```ts', 'const a = 1;', '```', '```', 'plain', '```');
  assert.deepEqual(extractMermaidBlocks(markdown), []);
});

test('finds every block in a document', () => {
  const markdown = doc('```mermaid', 'a', '```', 'text', '```mermaid', 'b', '```');
  assert.deepEqual(
    extractMermaidBlocks(markdown).map((b) => [b.line, b.code]),
    [
      [1, 'a'],
      [5, 'b'],
    ],
  );
});

test('an indented block keeps its own indentation, not the list item indent', () => {
  const markdown = doc('- item:', '', '  ```mermaid', '  graph TD;', '    A-->B;', '  ```');
  assert.deepEqual(extractMermaidBlocks(markdown), [{ line: 3, code: 'graph TD;\n  A-->B;' }]);
});

test('a mermaid fence nested inside a longer fence is content, not a diagram', () => {
  const markdown = doc('````markdown', '```mermaid', 'graph TD;', '```', '````');
  assert.deepEqual(extractMermaidBlocks(markdown), []);
});

test('a longer mermaid fence closes only on a fence at least as long', () => {
  const markdown = doc('````mermaid', 'graph TD;', '```', 'A-->B;', '````');
  assert.deepEqual(extractMermaidBlocks(markdown), [{ line: 1, code: 'graph TD;\n```\nA-->B;' }]);
});

test('a tilde fence is a fence too, and does not close a backtick one', () => {
  assert.deepEqual(extractMermaidBlocks(doc('~~~mermaid', 'graph TD;', '~~~')), [
    { line: 1, code: 'graph TD;' },
  ]);
  assert.deepEqual(extractMermaidBlocks(doc('```mermaid', 'a', '~~~', 'b', '```')), [
    { line: 1, code: 'a\n~~~\nb' },
  ]);
});

test('a fence with an info string beyond the language still counts', () => {
  assert.equal(extractMermaidBlocks(doc('```mermaid title=x', 'a', '```')).length, 1);
});

test('an unclosed fence yields no block rather than a truncated one', () => {
  assert.deepEqual(extractMermaidBlocks(doc('```mermaid', 'graph TD;')), []);
});

test('filesWithMermaid keeps only documents carrying a block', () => {
  const contents = {
    'a.md': '```mermaid\ngraph TD;\n```',
    'b.md': 'no diagrams here',
    'c.md': '```ts\nconst a = 1;\n```',
  };
  assert.deepEqual(
    filesWithMermaid(Object.keys(contents), (f) => contents[f]),
    ['a.md'],
  );
});

test('the probe renders a diagram this module owns, never one from the docs', () => {
  const seen = [];
  probeToolchain((code) => {
    seen.push(code);
    return { status: 0, stderr: '' };
  });
  assert.deepEqual(seen, [PROBE_DIAGRAM]);
  assert.match(PROBE_DIAGRAM, /^graph TD;/);
});

test('a toolchain that renders the known-good diagram is available', () => {
  assert.deepEqual(
    probeToolchain(() => ({ status: 0, stderr: '' })),
    { available: true },
  );
});

test('a toolchain that cannot render the known-good diagram is unavailable', () => {
  for (const stderr of [
    'Could not find Chrome (ver. 131). This can occur if either',
    'Error: Failed to launch the browser process!',
    'npm error code ENOTFOUND',
    'request to https://registry.npmjs.org/... failed, reason: getaddrinfo EAI_AGAIN',
    'could not run npx: spawnSync npx ENOENT',
  ]) {
    assert.deepEqual(
      probeToolchain(() => ({ status: 1, stderr })),
      { available: false, stderr },
    );
  }
});

// The regression that made this rewrite necessary: mmdc echoes the diagram
// source back in its parse errors, so the old stderr sniff let a broken diagram
// whose text mentioned "network" (or a timeout, or a missing command) classify
// itself as an environment problem and switch the gate off. Availability is now
// decided by the probe above, which the docs cannot reach.
test('a broken diagram whose text mentions the network is a parse failure, not a skip', () => {
  const stderr =
    'UnknownDiagramError: No diagram type detected matching given configuration ' +
    'for text: not a diagram but it mentions the network layer';
  const result = checkBlock('docs/architecture.md', { line: 3, code: 'x' }, () => ({
    status: 1,
    stderr,
  }));
  assert.equal(result.ok, undefined);
  assert.match(result.error, /^docs\/architecture\.md:3: mermaid block does not parse —/);
});

test('no word in a diagram can make checkBlock report anything but a parse failure', () => {
  for (const word of [
    'network',
    'timeout',
    'ETIMEDOUT',
    'command not found',
    'Could not find Chrome',
    'npm error',
    'registry.npmjs.org',
    'ECONNREFUSED',
  ]) {
    const result = checkBlock('a.md', { line: 1, code: word }, () => ({
      status: 1,
      stderr: `Parse error ... for text: ${word}`,
    }));
    assert.ok(result.error, `"${word}" should still be a parse failure`);
  }
});

test('a parse error names the file and the fence line', () => {
  const line = formatParseError('docs/architecture.md', { line: 42 }, 'Parse error on line 2:\n^');
  assert.equal(
    line,
    'docs/architecture.md:42: mermaid block does not parse — Parse error on line 2: ^',
  );
});

test('a parse error with no parser output still says something', () => {
  assert.match(formatParseError('a.md', { line: 1 }, ''), /no parser output/);
});

test('checkBlock passes a block the stubbed CLI accepts', () => {
  assert.deepEqual(
    checkBlock('a.md', { line: 1, code: 'graph TD;' }, () => ({ status: 0, stderr: '' })),
    { ok: true },
  );
});

test('checkBlock reports a parse failure as an error line', () => {
  const result = checkBlock('a.md', { line: 7, code: 'grph TD;' }, () => ({
    status: 1,
    stderr: 'Parse error on line 1',
  }));
  assert.equal(result.error, 'a.md:7: mermaid block does not parse — Parse error on line 1');
});

test('cleanOutput drops npx config chatter and keeps the diagnosis', () => {
  assert.equal(
    cleanOutput('npm warn Unknown project config "auto-install-peers".\nParse error on line 1'),
    'Parse error on line 1',
  );
  assert.equal(cleanOutput('npm notice a new version\n\nFailed to launch'), 'Failed to launch');
  assert.equal(cleanOutput(''), '');
  assert.equal(cleanOutput(undefined), '');
});

test('cleanOutput keeps at most the requested number of lines', () => {
  assert.equal(cleanOutput('a\nb\nc\nd\ne'), 'a b c d');
  assert.equal(cleanOutput('a\nb\nc', 2), 'a b');
});

test('checkBlock hands the CLI the block source unchanged', () => {
  const seen = [];
  checkBlock('a.md', { line: 1, code: 'graph TD;\n  A-->B;' }, (code) => {
    seen.push(code);
    return { status: 0, stderr: '' };
  });
  assert.deepEqual(seen, ['graph TD;\n  A-->B;']);
});

test('the mermaid CLI is pinned to an exact version', () => {
  assert.match(MERMAID_CLI, /^@mermaid-js\/mermaid-cli@\d+\.\d+\.\d+$/);
});

test('npx config noise is dropped from a parse error', () => {
  const line = formatParseError(
    'a.md',
    { line: 1 },
    'npm warn Unknown project config\nParse error',
  );
  assert.equal(line, 'a.md:1: mermaid block does not parse — Parse error');
});

test('the browser search prefers the first path that exists', () => {
  assert.equal(
    findBrowser(['/nowhere/chrome', '/usr/bin/chromium', '/usr/bin/google-chrome'], (p) =>
      p.startsWith('/usr/bin'),
    ),
    '/usr/bin/chromium',
  );
});

test('the browser search skips unset environment entries rather than crashing', () => {
  assert.equal(
    findBrowser([undefined, '', '/usr/bin/google-chrome'], () => true),
    '/usr/bin/google-chrome',
  );
});

test('no browser anywhere yields undefined, not a bogus path', () => {
  assert.equal(
    findBrowser(BROWSER_PATHS, () => false),
    undefined,
  );
});

test('the puppeteer config names the browser found and always disarms the sandbox', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'check-diagrams-test-'));
  try {
    const withBrowser = JSON.parse(
      readFileSync(writePuppeteerConfig(dir, '/usr/bin/chromium'), 'utf8'),
    );
    assert.equal(withBrowser.executablePath, '/usr/bin/chromium');
    assert.deepEqual(withBrowser.args, ['--no-sandbox', '--disable-dev-shm-usage']);

    // Without one, puppeteer must be left to its own download rather than
    // pointed at a path that does not exist.
    const without = JSON.parse(readFileSync(writePuppeteerConfig(dir, undefined), 'utf8'));
    assert.equal('executablePath' in without, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('changedDocs keeps the changed markdown outside the excluded subtrees', () => {
  const calls = [];
  const exec = (command, args) => {
    calls.push([command, ...args]);
    return 'README.md\nsrc/app.ts\ndocs/superpowers/plan.md\ndocs/ci.md\n';
  };
  assert.deepEqual(changedDocs(exec), ['README.md', 'docs/ci.md']);
  assert.deepEqual(calls, [['git', 'diff', '--name-only', 'origin/main...HEAD']]);
});

test('changedDocs is undefined when git cannot diff against origin/main', () => {
  assert.equal(
    changedDocs(() => {
      throw new Error('unknown revision origin/main');
    }),
    undefined,
  );
});

test('mmdcRunner renders each block through npx with its own input file', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'check-diagrams-runner-'));
  try {
    const calls = [];
    const spawn = (command, args) => {
      calls.push([command, args]);
      return { status: 0, stderr: 'warn\n', stdout: 'out' };
    };
    const run = mmdcRunner(dir, spawn, '/usr/bin/chromium');
    assert.deepEqual(run('graph TD;'), { status: 0, stderr: 'warn\nout' });
    run('graph LR;');
    const config = path.join(dir, 'puppeteer.json');
    assert.equal(JSON.parse(readFileSync(config, 'utf8')).executablePath, '/usr/bin/chromium');
    const first = path.join(dir, 'block-0.mmd');
    assert.deepEqual(calls[0], [
      'npx',
      ['--yes', MERMAID_CLI, '--quiet', '-p', config, '-i', first, '-o', `${first}.svg`],
    ]);
    assert.equal(readFileSync(first, 'utf8'), 'graph TD;\n');
    assert.equal(readFileSync(path.join(dir, 'block-1.mmd'), 'utf8'), 'graph LR;\n');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('mmdcRunner treats missing output streams as empty', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'check-diagrams-runner-'));
  try {
    const run = mmdcRunner(dir, () => ({ status: 1, stderr: null, stdout: null }), undefined);
    assert.deepEqual(run('x'), { status: 1, stderr: '' });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('mmdcRunner reports an npx that never started as a failure', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'check-diagrams-runner-'));
  try {
    const run = mmdcRunner(dir, () => ({ error: new Error('spawnSync npx ENOENT') }));
    assert.deepEqual(run('x'), { status: 1, stderr: 'could not run npx: spawnSync npx ENOENT' });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

const DIAGRAM = '```mermaid\ngraph TD;\n```';
const BROKEN = '```mermaid\ngrph TD;\n```';

/**
 * `main` against an in-memory doc set. `render(code)` stands in for the CLI;
 * the default renders everything. Returns the exit code, what it wrote, and
 * the directory the runner was handed.
 */
function runMain(argv, { docs = {}, render = () => ({ status: 0, stderr: '' }), ...io } = {}) {
  const out = [];
  const err = [];
  let runnerDir;
  const code = main(argv, {
    log: (line) => out.push(line),
    error: (line) => err.push(line),
    env: {},
    read: (file) => {
      if (!(file in docs)) throw new Error(`ENOENT: ${file}`);
      return docs[file];
    },
    listDocs: () => Object.keys(docs),
    changed: () => undefined,
    runner: (dir) => {
      runnerDir = dir;
      return render;
    },
    ...io,
  });
  return { code, out, err, runnerDir };
}

test('main checks only the files it is given', () => {
  const rendered = [];
  const result = runMain(['a.md'], {
    docs: { 'a.md': DIAGRAM, 'b.md': BROKEN },
    render: (code) => {
      rendered.push(code);
      return { status: 0, stderr: '' };
    },
  });
  assert.equal(result.code, 0);
  assert.deepEqual(result.out, ['diagrams ok (1 mermaid block(s) in 1 file(s))']);
  assert.deepEqual(rendered, [PROBE_DIAGRAM, 'graph TD;']);
  // The scratch directory is gone afterwards.
  assert.equal(existsSync(result.runnerDir), false);
});

test('main refuses a flag it does not know rather than passing', () => {
  for (const flag of ['--help', '-a', '--al']) {
    const result = runMain([flag], { docs: { 'a.md': DIAGRAM } });
    assert.equal(result.code, 1, flag);
    assert.deepEqual(result.out, [], flag);
    assert.deepEqual(result.err, [`::error::check-diagrams: unexpected ${flag}: pass --all and file paths`], flag);
  }
});

test('main fails on a file it is named that does not exist, naming every one', () => {
  const result = runMain(['a.md', 'gone.md', 'also-gone.md'], { docs: { 'a.md': DIAGRAM } });
  assert.equal(result.code, 1);
  assert.deepEqual(result.out, []);
  assert.deepEqual(result.err, ['::error::check-diagrams: no such file: gone.md, also-gone.md']);
});

test('main --all checks the whole doc set, whatever changed', () => {
  const result = runMain(['--all'], {
    docs: { 'a.md': DIAGRAM, 'b.md': DIAGRAM },
    changed: () => [],
  });
  assert.deepEqual(result.out, ['diagrams ok (2 mermaid block(s) in 2 file(s))']);
});

test('main with no arguments checks the docs changed against origin/main', () => {
  const result = runMain([], {
    docs: { 'a.md': DIAGRAM, 'b.md': DIAGRAM },
    changed: () => ['b.md'],
  });
  assert.deepEqual(result.out, ['diagrams ok (1 mermaid block(s) in 1 file(s))']);
});

test('main falls back to the whole doc set when git cannot tell what changed', () => {
  const result = runMain([], { docs: { 'a.md': DIAGRAM, 'b.md': DIAGRAM } });
  assert.deepEqual(result.out, ['diagrams ok (2 mermaid block(s) in 2 file(s))']);
});

test('main skips a changed doc deleted from the working tree', () => {
  const result = runMain([], { docs: { 'a.md': DIAGRAM }, changed: () => ['gone.md', 'a.md'] });
  assert.deepEqual(result.out, ['diagrams ok (1 mermaid block(s) in 1 file(s))']);
});

test('main without a mermaid block to check never starts the CLI', () => {
  const result = runMain(['a.md'], {
    docs: { 'a.md': 'no diagrams' },
    runner: () => assert.fail('the runner must not start'),
  });
  assert.equal(result.code, 0);
  assert.deepEqual(result.out, ['diagrams ok (no changed doc has a mermaid block)']);
});

test('main reports every block that does not parse and exits 1', () => {
  const result = runMain(['a.md', 'b.md'], {
    docs: { 'a.md': `${BROKEN}\n\n${BROKEN}`, 'b.md': DIAGRAM },
    render: (code) =>
      code.startsWith('grph') ? { status: 1, stderr: 'Parse error' } : { status: 0, stderr: '' },
  });
  assert.equal(result.code, 1);
  assert.deepEqual(result.out, []);
  assert.deepEqual(result.err, [
    'a.md:1: mermaid block does not parse — Parse error',
    'a.md:5: mermaid block does not parse — Parse error',
    'diagrams: 2 mermaid block(s) do not parse',
  ]);
});

test('main skips with a warning when the toolchain cannot render locally', () => {
  const rendered = [];
  const result = runMain(['a.md'], {
    docs: { 'a.md': DIAGRAM },
    render: (code) => {
      rendered.push(code);
      return { status: 1, stderr: 'npm warn config\nnpm error code ENOTFOUND\ngetaddrinfo\nmore' };
    },
  });
  assert.equal(result.code, 0);
  // Only the probe ran: no doc block reached the CLI.
  assert.deepEqual(rendered, [PROBE_DIAGRAM]);
  assert.deepEqual(result.err, [
    `warning: mermaid check skipped: ${MERMAID_CLI} could not render a known-good diagram ` +
      '(npm error code ENOTFOUND getaddrinfo) — this gate needs the network on a cold npx cache',
  ]);
});

test('main fails under CI when the toolchain cannot render', () => {
  const result = runMain(['a.md'], {
    docs: { 'a.md': DIAGRAM },
    env: { CI: 'true' },
    render: () => ({ status: 1, stderr: '' }),
  });
  assert.equal(result.code, 1);
  assert.deepEqual(result.err, [
    `::error::diagrams: ${MERMAID_CLI} could not render a known-good diagram (no output)`,
  ]);
});

// The command line, end to end, offline: a scratch directory outside any git
// repository has no origin/main, so the whole (mermaid-free) doc set is read
// and the CLI never starts. The environment is inherited so a coverage run
// sees the child too.
test('as a command it passes a doc set without diagrams without starting the CLI', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'check-diagrams-cli-'));
  try {
    writeFileSync(path.join(dir, 'README.md'), '# Title\n');
    const result = spawnSync(
      process.execPath,
      [fileURLToPath(new URL('./bin/check-diagrams.mjs', import.meta.url))],
      { cwd: dir, encoding: 'utf8', env: { ...process.env, GIT_CEILING_DIRECTORIES: dir } },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'diagrams ok (no changed doc has a mermaid block)\n');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line), runner: () => assert.fail('--help ran something') });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +check-diagrams(?: |$)/m);
  assert.deepEqual(err, []);
});
