// check-code-scanning run against fakes of `codeql` and `gh` on a PATH that
// holds nothing else, so a CodeQL CLI installed on this machine (or `gh`, which
// every GitHub runner has) can never answer instead of the fake. The fakes
// record every call; no database is built and nothing is downloaded.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { capture, findings, main, onPath, parseArgs, plan, summarize, yamlList } from './bin/check-code-scanning.mjs';

const BIN = fileURLToPath(new URL('./bin/check-code-scanning.mjs', import.meta.url));
let work;
let impl;

const CONFIG = '.github/codeql/codeql-config.yml';

// The same shape as a real configuration, comments included: the parser has to
// see past them.
const DEFAULT_CONFIG = `name: fixture

# A comment between keys, with a list-looking line in it:
#   - uses: not-a-suite
queries:
  - uses: security-and-quality

packs:
  - codeql/javascript-queries:AlertSuppression.ql

paths-ignore:
  - src/graphql/generated # generated
  # a comment inside the list
  - ios
  - .claude/worktrees # other checkouts
`;

const CODEQL_IMPL = `#!/bin/bash
printf 'codeql %s\\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  'version --format=terse') echo 2.99.0 ;;
  'database create')
    printf 'filters<<%s>>\\n' "$LGTM_INDEX_FILTERS" >> "$FAKE_LOG"
    for i in {1..40}; do echo "create log line $i"; done
    exit "\${FAKE_CREATE_STATUS:-0}"
    ;;
  'database analyze')
    echo 'analyze log line'
    sarif="\${FAKE_SARIF:-}"
    [ -n "$sarif" ] || sarif='{"runs":[]}'
    for arg in "$@"; do case "$arg" in --output=*) printf '%s' "$sarif" > "\${arg#--output=}" ;; esac; done
    exit "\${FAKE_ANALYZE_STATUS:-0}"
    ;;
  *) echo "unexpected codeql call: $*" >&2; exit 99 ;;
esac
`;

const fakeGh = (implPath) => `#!/bin/bash
printf 'gh %s\\n' "$*" >> "$FAKE_LOG"
case "$1" in
  extension) printf '%s\\n' "\${FAKE_GH_EXTENSIONS:-}" ;;
  codeql) shift; exec "${implPath}" "$@" ;;
  *) exit 99 ;;
esac
`;

function executable(file, text) {
  writeFileSync(file, text);
  chmodSync(file, 0o755);
}

before(() => {
  work = mkdtempSync(path.join(tmpdir(), 'code-scanning-'));
  impl = path.join(work, 'codeql-impl');
  executable(impl, CODEQL_IMPL);
});
after(() => {
  rmSync(work, { recursive: true, force: true });
});

const result = (ruleId, uri, line, text, extra = {}) => ({
  ruleId,
  message: { text },
  locations: [{ physicalLocation: { artifactLocation: { uri }, region: { startLine: line } } }],
  ...extra,
});

// One suppressed finding, one open one, and - in a second run - one with no
// location and no rule id, which is the shape that used to throw.
const SARIF = {
  runs: [
    {
      results: [
        result('js/insufficient-password-hash', 'src/auth.ts', 45, 'Password  from\n a call.', { suppressions: [{ kind: 'inSource' }] }),
        result('js/unused-local-variable', 'src/x.ts', 3, 'Unused variable y.'),
      ],
    },
    { results: [{ ruleId: 'js/no-location', message: { text: 'nowhere' } }] },
  ],
};

/**
 * @param {object} options
 * @param {string | null} [options.config] the CodeQL configuration, null for none
 * @param {Array<'codeql' | 'gh'>} [options.tools] which CLIs are on PATH
 */
function run({ config = DEFAULT_CONFIG, tools = ['codeql'], env = {}, argv = [] } = {}) {
  const dir = mkdtempSync(path.join(work, 'case-'));
  const repo = path.join(dir, 'repo');
  mkdirSync(repo);
  if (config !== null) {
    mkdirSync(path.join(repo, '.github', 'codeql'), { recursive: true });
    writeFileSync(path.join(repo, CONFIG), config);
  }
  const bin = path.join(dir, 'bin');
  mkdirSync(bin);
  if (tools.includes('codeql')) symlinkSync(impl, path.join(bin, 'codeql'));
  if (tools.includes('gh')) executable(path.join(bin, 'gh'), fakeGh(impl));
  const log = path.join(dir, 'calls.log');
  writeFileSync(log, '');
  const out = { stdout: [], stderr: [] };
  const status = main(argv, {
    cwd: repo,
    env: { PATH: bin, FAKE_LOG: log, ...env },
    log: (line) => out.stdout.push(line),
    error: (line) => out.stderr.push(line),
  });
  return {
    status,
    repo,
    stdout: out.stdout.join('\n'),
    stderr: out.stderr.join('\n'),
    calls: readFileSync(log, 'utf8').trimEnd().split('\n').filter(Boolean),
  };
}

const SUITE = 'codeql/javascript-queries:codeql-suites/javascript-security-and-quality.qls';
const SUPPRESSION = 'codeql/javascript-queries:AlertSuppression.ql';
const CREATE = 'codeql database create .codeql/db --language=javascript-typescript --source-root . --overwrite';
const analyze = (...queries) =>
  `codeql database analyze .codeql/db ${queries.join(' ')} --download --format=sarif-latest --output=.codeql/results.sarif`;

describe('finding the CLI', () => {
  test('no codeql and no gh: says how to install one and fails before touching anything', () => {
    const r = run({ tools: [] });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /no CodeQL CLI found/);
    assert.match(r.stderr, /gh extension install github\/gh-codeql/);
    assert.match(r.stderr, /brew install codeql/);
    assert.deepEqual(r.calls, []);
    assert.equal(existsSync(path.join(r.repo, '.codeql')), false);
  });

  test('gh without the codeql extension counts as no CLI', () => {
    const r = run({ tools: ['gh'], env: { FAKE_GH_EXTENSIONS: 'gh dash  dlvhdr/gh-dash  v4.0.0' } });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /no CodeQL CLI found/);
    assert.deepEqual(r.calls, ['gh extension list']);
  });

  test('gh with the codeql extension drives every step through `gh codeql`', () => {
    const r = run({ tools: ['gh'], env: { FAKE_GH_EXTENSIONS: 'gh codeql  github/gh-codeql  v1.1.0' } });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(
      r.calls.filter((line) => line.startsWith('gh ')),
      ['gh extension list', 'gh codeql version --format=terse', `gh ${CREATE}`, `gh ${analyze(SUITE, SUPPRESSION)}`],
    );
  });

  test('a codeql on PATH wins over gh, which is then never asked', () => {
    const r = run({ tools: ['codeql', 'gh'], env: { FAKE_GH_EXTENSIONS: 'gh codeql  github/gh-codeql  v1.1.0' } });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.calls.filter((line) => line.startsWith('gh ')).length, 0);
  });

  test('onPath needs an executable, and reads no PATH as empty', () => {
    const dir = mkdtempSync(path.join(work, 'path-'));
    writeFileSync(path.join(dir, 'plain'), '');
    assert.equal(onPath('plain', { PATH: dir }), false);
    assert.equal(onPath('plain', {}), false);
  });

  test('capture reads a command that cannot start as no output', () => {
    assert.deepEqual(capture('no-such-command-here', [], { cwd: work, env: { PATH: work } }), { status: null, stdout: '' });
  });
});

describe('the run', () => {
  test('the suite, packs and ignored paths from the configuration reach CodeQL', () => {
    const r = run();
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.calls, [
      'codeql version --format=terse',
      CREATE,
      'filters<<exclude:ios',
      'exclude:android',
      'exclude:dist',
      'exclude:coverage',
      'exclude:vendor/bundle',
      'exclude:.expo',
      'exclude:.workflows',
      'exclude:.claude/worktrees',
      'exclude:src/graphql/generated',
      'exclude:.codeql>>',
      analyze(SUITE, SUPPRESSION),
    ]);
    assert.deepEqual(r.stdout.split('\n'), [
      `== codeql 2.99.0, config ${CONFIG}`,
      `== database (javascript-typescript, no build step; 10 index filters from ${CONFIG})`,
      `== analyze: ${SUITE} ${SUPPRESSION} (the pack is downloaded once)`,
      '== findings (.codeql/results.sarif)',
      'codeql: no findings',
    ]);
    assert.equal(r.stderr, '');
    assert.ok(existsSync(path.join(r.repo, '.codeql', 'create.log')));
    assert.ok(existsSync(path.join(r.repo, '.codeql', 'analyze.log')));
  });

  test('an open finding fails the gate, and every finding is listed', () => {
    const r = run({ env: { FAKE_SARIF: JSON.stringify(SARIF) } });
    assert.equal(r.status, 1);
    assert.deepEqual(r.stdout.split('\n').slice(-4), summarize(SARIF).lines);
  });

  test('a SARIF log that does not parse fails the gate', () => {
    const r = run({ env: { FAKE_SARIF: '{' } });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /^::error::could not read \.codeql\/results\.sarif: /);
  });

  test('--config names another configuration file', () => {
    const r = run({ config: null, argv: ['--config', 'codeql.yml'] });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.split('\n')[0], '== codeql 2.99.0, config codeql.yml');
    const dir = r.repo;
    writeFileSync(path.join(dir, 'codeql.yml'), DEFAULT_CONFIG);
    const out = [];
    const status = main(['--root', dir, '--config', 'codeql.yml'], {
      cwd: work,
      env: { PATH: path.join(path.dirname(dir), 'bin'), FAKE_LOG: path.join(path.dirname(dir), 'calls.log') },
      log: (line) => out.push(line),
      error: (line) => out.push(line),
    });
    assert.equal(status, 0, out.join('\n'));
    assert.equal(out[0], '== codeql 2.99.0, config codeql.yml');
  });

  test('a repository with no configuration of its own is analysed on the family defaults', () => {
    const r = run({ config: null });
    assert.equal(r.status, 0, r.stderr);
    assert.ok(r.calls.includes(analyze(SUITE, SUPPRESSION)), r.calls.join('\n'));
    assert.ok(r.calls.includes('filters<<exclude:ios'), r.calls.join('\n'));
    assert.match(r.stdout, /; 9 index filters from /);
    assert.equal(r.stderr, '');
  });

  test('a key the merge does not carry fails the run, naming it', () => {
    const r = run({ config: 'paths:\n  - src\n' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /::error::\.github\/codeql\/codeql-config\.yml sets paths, which the merge/);
    assert.deepEqual(r.calls, []);
  });

  test('a configuration that cannot be read for another reason than being absent fails the run', () => {
    const dir = mkdtempSync(path.join(work, 'unreadable-'));
    mkdirSync(path.join(dir, '.github', 'codeql', 'codeql-config.yml'), { recursive: true });
    const bin = path.join(dir, 'bin');
    mkdirSync(bin);
    symlinkSync(impl, path.join(bin, 'codeql'));
    const out = [];
    const status = main(['--root', dir], { cwd: dir, env: { PATH: bin }, log: (line) => out.push(line), error: (line) => out.push(line) });
    assert.equal(status, 1, out.join('\n'));
    assert.match(out.join('\n'), /EISDIR|illegal operation on a directory/);
  });

  test('a failed database create shows the last 30 log lines and stops', () => {
    const r = run({ env: { FAKE_CREATE_STATUS: '2' } });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /create log line 11\n/);
    assert.match(r.stderr, /create log line 40\n/);
    assert.doesNotMatch(r.stderr, /create log line 10\n/);
    assert.match(r.stderr, /::error::database create failed \(full log: \.codeql\/create\.log\)/);
    assert.equal(r.calls.some((line) => line.includes('analyze')), false);
  });

  test('a failed analyze shows its log and stops before the findings report', () => {
    const r = run({ env: { FAKE_ANALYZE_STATUS: '2' } });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /analyze log line/);
    assert.match(r.stderr, /::error::analyze failed \(full log: \.codeql\/analyze\.log\)/);
    assert.doesNotMatch(r.stdout, /== findings/);
  });
});

describe('reading the configuration', () => {
  test('no queries entry at all is refused', () => {
    const r = run({ config: 'name: fixture\nqueries:\npacks:\n  - codeql/javascript-queries:AlertSuppression.ql\n' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /::error::.* names 0 entries under 'queries:'; this check maps exactly one suite/);
    assert.equal(r.calls.some((line) => line.includes('database')), false);
  });

  test('two queries entries are refused rather than analysing less than CI', () => {
    const r = run({ config: 'queries:\n  - uses: security-and-quality\n  - uses: security-extended\n' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /names 2 entries under 'queries:'/);
  });

  test('a queries entry that is not `uses:` is refused', () => {
    const r = run({ config: 'queries:\n  - name: custom\n' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /::error::unsupported 'queries:' entry 'name: custom' in .* - expected 'uses: <suite>'/);
  });

  for (const form of ['', './queries/local.qls', 'acme/pack', 'one.ql', 'many.qls']) {
    test(`a \`uses:\` of anything but a bare suite name is refused: '${form}'`, () => {
      const r = run({ config: `queries:\n  - uses: ${form}\n` });
      assert.equal(r.status, 1);
      assert.ok(r.stderr.includes(`::error::unsupported 'uses:' form '${form}' in ${CONFIG}`), r.stderr);
      assert.equal(r.calls.some((line) => line.includes('database')), false);
    });
  }

  test('a suite name with extra spacing and a trailing comment is read as the bare name', () => {
    const r = run({
      config: 'queries:\n  -   uses:    security-extended   # the default plus more\npacks:\n  - codeql/javascript-queries:AlertSuppression.ql\n',
    });
    assert.equal(r.status, 0, r.stderr);
    assert.ok(r.calls.includes(analyze('codeql/javascript-queries:codeql-suites/javascript-security-extended.qls', SUPPRESSION)), r.calls.join('\n'));
  });

  test('a pack without a scope is refused', () => {
    const r = run({ config: 'queries:\n  - uses: security-and-quality\npacks:\n  - AlertSuppression.ql\n' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /::error::unsupported 'packs:' entry 'AlertSuppression\.ql' in .* - expected <scope>\/<name>\[:<path>\]/);
  });

  test('packs without AlertSuppression.ql warn that suppression markers do nothing, then run', () => {
    const r = run({ config: 'queries:\n  - uses: security-and-quality\npacks:\n  - acme/extra-queries\n' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /::warning::.* loads no AlertSuppression\.ql pack/);
    assert.ok(r.calls.includes(analyze(SUITE, 'acme/extra-queries')), r.calls.join('\n'));
  });

  test('a file that sets only its own paths-ignore keeps the family suite, packs and paths', () => {
    const r = run({ config: 'paths-ignore:\n  - generated/**\n' });
    assert.equal(r.status, 0, r.stderr);
    assert.ok(r.calls.includes(analyze(SUITE, SUPPRESSION)), r.calls.join('\n'));
    assert.ok(r.calls.includes('exclude:generated/**'), r.calls.join('\n'));
    assert.ok(r.calls.includes('filters<<exclude:ios'), r.calls.join('\n'));
  });

  test('yamlList reads only its own block', () => {
    const text = 'queries:\n  - uses: a # c\n  -\nother:\n  - x\n';
    assert.deepEqual(yamlList(text, 'queries'), ['uses: a']);
    assert.deepEqual(yamlList(text, 'missing'), []);
  });

  test('plan maps the language to its pack', () => {
    assert.deepEqual(plan('queries:\n  - uses: code-scanning\n', 'c.yml', 'javascript-typescript').queries, [
      'codeql/javascript-queries:codeql-suites/javascript-code-scanning.qls',
    ]);
  });
});

describe('the findings', () => {
  test('reads rule, location, message and the in-source suppression from every run', () => {
    assert.deepEqual(findings(SARIF), [
      { ruleId: 'js/insufficient-password-hash', location: 'src/auth.ts:45', message: 'Password from a call.', suppressed: true },
      { ruleId: 'js/unused-local-variable', location: 'src/x.ts:3', message: 'Unused variable y.', suppressed: false },
      { ruleId: 'js/no-location', location: '<no location>', message: 'nowhere', suppressed: false },
    ]);
  });

  test('tolerates a SARIF with no runs, results, rule or message', () => {
    assert.deepEqual(findings({}), []);
    assert.deepEqual(findings({ runs: [{}] }), []);
    assert.deepEqual(findings({ runs: [{ results: [{ locations: [{ physicalLocation: { artifactLocation: { uri: 'a.ts' } } }] }] }] }), [
      { ruleId: '<no rule>', location: 'a.ts', message: '', suppressed: false },
    ]);
  });

  test('an empty suppressions array is not a suppression', () => {
    assert.equal(findings({ runs: [{ results: [result('js/x', 'a.ts', 1, 'm', { suppressions: [] })] }] })[0].suppressed, false);
  });

  test('lists every finding, marks the suppressed ones and counts both', () => {
    const { open, suppressed, lines } = summarize(SARIF);
    assert.equal(open, 2);
    assert.equal(suppressed, 1);
    assert.deepEqual(lines, [
      'suppressed  js/insufficient-password-hash  src/auth.ts:45  Password from a call.',
      'open        js/unused-local-variable  src/x.ts:3  Unused variable y.',
      'open        js/no-location  <no location>  nowhere',
      'codeql: 2 open, 1 suppressed by an inline marker',
    ]);
  });

  test('says so when there is nothing', () => {
    assert.deepEqual(summarize({ runs: [] }), { open: 0, suppressed: 0, lines: ['codeql: no findings'] });
  });

  test('a run whose every finding is suppressed reports zero open, so the gate passes', () => {
    const { open, suppressed, lines } = summarize({ runs: [{ results: [result('js/x', 'a.ts', 1, 'm', { suppressions: [{ kind: 'inSource' }] })] }] });
    assert.equal(open, 0);
    assert.equal(suppressed, 1);
    assert.equal(lines.at(-1), 'codeql: 0 open, 1 suppressed by an inline marker');
  });
});

test('parseArgs reads every option, refuses a language it has no mapping for, and anything else', () => {
  assert.deepEqual(parseArgs([], '/w'), { root: '/w', config: '.github/codeql/codeql-config.yml', language: 'javascript-typescript' });
  assert.deepEqual(parseArgs(['--root', 'app', '--config', 'c.yml', '--language', 'javascript-typescript'], '/w'), {
    root: path.resolve('/w', 'app'),
    config: 'c.yml',
    language: 'javascript-typescript',
  });
  assert.throws(() => parseArgs(['--language', 'python'], '/w'), /--language python is not mapped; this check knows javascript-typescript/);
  assert.throws(() => parseArgs(['--config'], '/w'), /unexpected --config: pass --root DIR, --config FILE and --language LANGUAGE/);
  const out = [];
  assert.equal(main(['--nope'], { error: (line) => out.push(line) }), 1);
  assert.deepEqual(out, ['code scanning: unexpected --nope: pass --root DIR, --config FILE and --language LANGUAGE']);
});

test('as a command it finds the CLI on PATH and runs in --root', () => {
  const r = run({ tools: [] });
  const bin = path.join(path.dirname(r.repo), 'bin');
  symlinkSync(impl, path.join(bin, 'codeql'));
  const log = path.join(path.dirname(r.repo), 'calls.log');
  const child = spawnSync(process.execPath, [BIN, '--root', r.repo], { encoding: 'utf8', env: { ...process.env, PATH: bin, FAKE_LOG: log } });
  assert.equal(child.status, 0, child.stderr);
  assert.match(child.stdout, /codeql: no findings\n$/);
});
