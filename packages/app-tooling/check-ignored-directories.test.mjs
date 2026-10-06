import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  biomeExtends,
  evaluate,
  jestProblems,
  main,
  metroProblems,
  namesDirectory,
  parseArgs,
  stripComments,
  TEXT_CHECKS,
  zizmorCalls,
  zizmorProblems,
} from './bin/check-ignored-directories.mjs';

// Git's own variables are dropped: a pre-push hook exports GIT_DIR, which would
// point every git call here at the repository being pushed.
const clean = () => Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
const BIN = fileURLToPath(new URL('./bin/check-ignored-directories.mjs', import.meta.url));
const DIRS = ['.workflows', '.claude/worktrees'];
let work;
before(() => {
  work = mkdtempSync(path.join(tmpdir(), 'ignored-directories-'));
});
after(() => {
  rmSync(work, { recursive: true, force: true });
});

const check = (tool) => TEXT_CHECKS.find((c) => c.tool === tool);
/** Which of the two directories a text check finds skipped in `text`. */
const skipped = (tool, text) => DIRS.filter((dir) => check(tool).skips(check(tool).parse(text), dir));

describe('reading the configurations', () => {
  test('namesDirectory takes the directory with or without a leading slash, a trailing slash or /**, or **/ before it', () => {
    for (const entry of ['.workflows', '/.workflows', '.workflows/', '/.workflows/', '.workflows/**', '**/.workflows', ' .workflows ']) {
      assert.ok(namesDirectory(entry, '.workflows'), entry);
    }
    for (const entry of ['.workflowsx', 'x.workflows', '.workflows/a', '# .workflows', 'src']) assert.ok(!namesDirectory(entry, '.workflows'), entry);
    assert.ok(namesDirectory('.claude/worktrees/', '.claude/worktrees'));
  });

  test('stripComments removes comments outside strings only', () => {
    assert.deepEqual(JSON.parse(stripComments('{ // a\n "a": "x//y", /* b */ "b": "/*z*/" }')), { a: 'x//y', b: '/*z*/' });
  });

  test('Biome: a negated files.includes entry, forced or not, or the older files.ignore', () => {
    assert.deepEqual(skipped('Biome', '{"files":{"includes":["**","!**/.workflows","!!.claude/worktrees"]}}'), DIRS);
    assert.deepEqual(skipped('Biome', '{"files":{"includes":["**",".workflows"]}}'), []);
    assert.deepEqual(skipped('Biome', '{"files":{"ignore":[".workflows"]}}'), ['.workflows']);
    assert.deepEqual(skipped('Biome', '{}'), []);
  });

  test('tsc: exclude names it, or every include is rooted', () => {
    assert.deepEqual(skipped('tsc', '{"exclude":["node_modules",".workflows",".claude/worktrees"]}'), DIRS);
    assert.deepEqual(skipped('tsc', '{"include":["src","app.config.ts"]}'), DIRS);
    assert.deepEqual(skipped('tsc', '{"include":["**/*.ts"]}'), []);
    assert.deepEqual(skipped('tsc', '{}'), []);
  });

  test('knip: ignore names it, or no entry or project glob starts at a dot directory', () => {
    assert.deepEqual(skipped('knip', '{"entry":["src/index.ts"],"project":["src/**","scripts/**/*.mjs"]}'), DIRS);
    assert.deepEqual(skipped('knip', '{}'), DIRS);
    assert.deepEqual(skipped('knip', '{"project":["**/*.ts",".github/**"]}'), []);
    assert.deepEqual(skipped('knip', '{"project":"src/.x/**","ignore":".workflows/**"}'), ['.workflows']);
  });

  test('typos: extend-exclude names it, over one line or several', () => {
    assert.deepEqual(skipped('typos', '[files]\nextend-exclude = [".workflows/", \'.claude/worktrees/\', "*.po"]\n'), DIRS);
    assert.deepEqual(skipped('typos', '[files]\nextend-exclude = [\n  ".workflows",\n]\n'), ['.workflows']);
    assert.deepEqual(skipped('typos', '[files]\n'), []);
  });

  test('git and Semgrep: a line of the ignore file names it', () => {
    assert.deepEqual(skipped('git', '# worktrees\n/.claude/worktrees/\n/.workflows\n'), DIRS);
    assert.deepEqual(skipped('Semgrep', '.claude/worktrees/\n'), ['.claude/worktrees']);
  });

  test('CodeQL: paths-ignore names it, a trailing comment and all', () => {
    const config = 'paths-ignore:\n  - .workflows # the workflows\n  - .claude/worktrees\nqueries:\n  - uses: x\n';
    assert.deepEqual(skipped('CodeQL', config), DIRS);
    assert.deepEqual(skipped('CodeQL', 'queries:\n  - .workflows\n'), []);
  });
});

describe('Jest', () => {
  // The template's shape: an app project anchored to <rootDir> for worktrees,
  // and a plugins project whose testMatch is rooted in plugins/.
  const worktrees = '<rootDir>/\\.claude/worktrees/';
  const both = ['<rootDir>/\\.workflows/', worktrees];
  const aligned = {
    projects: [
      { displayName: 'app', testPathIgnorePatterns: both, modulePathIgnorePatterns: both, coveragePathIgnorePatterns: both },
      { displayName: { name: 'plugins' }, testMatch: ['<rootDir>/plugins/**/*.test.ts'], modulePathIgnorePatterns: both, coveragePathIgnorePatterns: both },
    ],
  };

  test('an aligned configuration skips both, from this root and from a root that is a worktree', () => {
    for (const dir of DIRS) assert.deepEqual(jestProblems(aligned, '/r', dir, '.claude/worktrees'), [], dir);
  });

  test('a configuration without projects is one project', () => {
    assert.deepEqual(jestProblems({ testPathIgnorePatterns: both, modulePathIgnorePatterns: both, coveragePathIgnorePatterns: both }, '/r', '.workflows', '.claude/worktrees'), []);
  });

  test('a missing pattern is named by project and option, with the pattern to add', () => {
    const problems = jestProblems({ projects: [{ testPathIgnorePatterns: [worktrees] }, 'packages/x'] }, '/r', '.workflows', '.claude/worktrees');
    assert.deepEqual(problems, [
      "Jest (project 1) testPathIgnorePatterns does not skip .workflows: add '<rootDir>/\\\\.workflows/'",
      "Jest (project 1) modulePathIgnorePatterns does not skip .workflows: add '<rootDir>/\\\\.workflows/'",
      "Jest (project 1) coveragePathIgnorePatterns does not skip .workflows: add '<rootDir>/\\\\.workflows/'",
    ]);
  });

  test('an unanchored worktrees pattern hides every test when the root is itself a worktree', () => {
    const loose = ['/\\.claude/worktrees/'];
    const problems = jestProblems({ testPathIgnorePatterns: loose, modulePathIgnorePatterns: loose, coveragePathIgnorePatterns: loose }, '/r', '.claude/worktrees', '.claude/worktrees');
    assert.deepEqual(problems, [
      'Jest (project 1) testPathIgnorePatterns hides this checkout when its root is under .claude/worktrees: anchor the .claude/worktrees pattern to <rootDir>',
      'Jest (project 1) modulePathIgnorePatterns hides this checkout when its root is under .claude/worktrees: anchor the .claude/worktrees pattern to <rootDir>',
      'Jest (project 1) coveragePathIgnorePatterns hides this checkout when its root is under .claude/worktrees: anchor the .claude/worktrees pattern to <rootDir>',
    ]);
    // For a directory that never holds a checkout, an unanchored pattern is fine.
    const workflows = ['/\\.workflows/'];
    assert.deepEqual(jestProblems({ testPathIgnorePatterns: workflows, modulePathIgnorePatterns: workflows, coveragePathIgnorePatterns: workflows }, '/r', '.workflows', '.claude/worktrees'), []);
  });

  test('a pattern written for this root alone misses a root that is a worktree', () => {
    const fixed = ['^/r/\\.claude/worktrees/'];
    const problems = jestProblems({ testPathIgnorePatterns: fixed, modulePathIgnorePatterns: fixed, coveragePathIgnorePatterns: fixed }, '/r', '.claude/worktrees', '.claude/worktrees');
    assert.equal(problems[0], "Jest (project 1) testPathIgnorePatterns does not skip .claude/worktrees from a root under .claude/worktrees: add '<rootDir>/\\\\.claude/worktrees/'");
    assert.equal(problems.length, 3);
  });

  test('a pattern that hides this checkout from its own root is named', () => {
    const all = ['/src/', worktrees];
    const problems = jestProblems({ testPathIgnorePatterns: all, modulePathIgnorePatterns: [worktrees], coveragePathIgnorePatterns: [worktrees] }, '/r', '.claude/worktrees', 'elsewhere');
    assert.deepEqual(problems, ['Jest (project 1) testPathIgnorePatterns hides this checkout: anchor the .claude/worktrees pattern to <rootDir>']);
  });

  test('a testMatch is rooted only when its first directory is a plain name', () => {
    const rest = { modulePathIgnorePatterns: both, coveragePathIgnorePatterns: both };
    for (const glob of ['<rootDir>/**/*.test.ts', '<rootDir>/.hidden/*.test.ts', '<rootDir>/p*/x.test.ts', '**/*.test.ts']) {
      assert.equal(jestProblems({ testMatch: [glob], ...rest }, '/r', '.workflows', 'x').length, 1, glob);
    }
  });
});

describe('Metro', () => {
  const anchored = (root) => [[`^(?:${root.replaceAll('/', '\\/')}\\/)?\\.claude[\\\\/]worktrees(?:[\\\\/]|$)`, '']];

  test('an anchored block of the directory passes', () => {
    assert.deepEqual(metroProblems(anchored('/r'), '/r', '.claude/worktrees'), []);
  });

  test('a missing block is named', () => {
    assert.deepEqual(metroProblems([], '/r', '.workflows'), ["Metro's resolver.blockList does not block .workflows"]);
  });

  test('a block of only the absolute path misses what the crawler asks about', () => {
    assert.deepEqual(metroProblems([['^\\/r\\/\\.workflows\\/', '']], '/r', '.workflows'), [
      "Metro's resolver.blockList does not block the relative .workflows, which Expo's crawler asks about",
    ]);
  });

  test('a block that reaches this checkout, or a sibling sharing the prefix, is named', () => {
    assert.deepEqual(metroProblems([['\\.workflows', ''], ['src', 'i']], '/r', '.workflows'), [
      "Metro's resolver.blockList blocks this checkout: anchor the .workflows pattern to the root",
      "Metro's resolver.blockList blocks .workflows-notes too: end the .workflows pattern at a separator",
    ]);
  });
});

describe('zizmor', () => {
  test('a call without --config is named, and one with it passes', () => {
    assert.deepEqual(
      zizmorProblems(['Makefile:3:\tzizmor --offline --config .github/zizmor.yml .github', 'scripts/a.sh:9:zizmor --offline .github', 'b.yml:1:x: zizmor --config=z.yml .']),
      ['scripts/a.sh:9:zizmor --offline .github'],
    );
  });

  test('zizmorCalls reads the tracked files, not markdown, and no match is no call', () => {
    const repo = mkdtempSync(path.join(work, 'grep-'));
    const env = { ...clean(), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CEILING_DIRECTORIES: work };
    const git = (...args) => execFileSync('git', args, { cwd: repo, env });
    git('init', '-q');
    writeFileSync(path.join(repo, 'README.md'), 'zizmor --offline .\n');
    writeFileSync(path.join(repo, 'a.sh'), 'echo\n');
    git('add', '-A');
    assert.deepEqual(zizmorCalls(repo, env), []);
    writeFileSync(path.join(repo, 'b.sh'), 'x=1\n"zizmor" --offline .\nzizmor --offline .\n');
    git('add', '-A');
    assert.deepEqual(zizmorCalls(repo, env), ['b.sh:3:zizmor --offline .']);
    assert.throws(() => zizmorCalls(path.join(work, 'no-such-directory'), env));
  });
});

test('parseArgs takes the directories, the worktrees directory and the root', () => {
  assert.deepEqual(parseArgs([], '/w'), { root: '/w', directories: DIRS, worktrees: '.claude/worktrees' });
  assert.deepEqual(parseArgs(['--root', 'app', '--directory', 'vendor/', '--directory', '.wt', '--worktrees', '.wt'], '/w'), {
    root: path.resolve('/w', 'app'),
    directories: ['vendor', '.wt'],
    worktrees: '.wt',
  });
  for (const bad of [['--directory', '/abs'], ['--worktrees', '/abs'], ['--directory'], ['--nope', 'x']]) {
    assert.throws(() => parseArgs(bad, '/w'), /unexpected .*: pass --root DIR, --directory RELATIVE-DIR and --worktrees RELATIVE-DIR/, bad.join(' '));
  }
});

/** main over an in-memory tree; `loaded` answers the child processes by kind. */
function run(files, { argv = [], loaded = {}, calls = [] } = {}) {
  const out = { log: [], error: [] };
  const code = main(argv, {
    cwd: '/r',
    // A package specifier resolves to its file under node_modules, as Node would.
    resolve: (specifier) => path.join('/r', 'node_modules', `${specifier}.json`),
    read: (file) => {
      const text = files[path.relative('/r', file)];
      if (text === undefined) throw new Error(`ENOENT: ${file}`);
      return text;
    },
    exists: (file) => path.relative('/r', file) in files,
    grep: () => {
      if (calls instanceof Error) throw calls;
      return calls;
    },
    run: (code_, args) => {
      const kind = code_.includes('isPathIgnored') ? 'eslint' : code_.includes('blockList') ? 'metro' : 'jest';
      const answer = loaded[kind];
      if (answer instanceof Error) throw answer;
      return typeof answer === 'function' ? answer(args) : answer;
    },
    log: (line) => out.log.push(line),
    error: (line) => out.error.push(line),
  });
  return { code, ...out };
}

const ALIGNED = {
  'biome.json': '{"files":{"includes":["**","!!**/.workflows","!!.claude/worktrees"]}}',
  'tsconfig.json': '{"exclude":[".workflows",".claude/worktrees"]}',
  'knip.json': '{"project":["src/**"]}',
  'typos.toml': 'extend-exclude = [".workflows/", ".claude/worktrees/"]\n',
  '.gitignore': '/.workflows\n/.claude/worktrees/\n',
};

test('every text check says how to fix it', () => {
  const { error } = run({
    'biome.json': '{}',
    'tsconfig.json': '{}',
    'knip.json': '{"project":[".x/**"]}',
    'typos.toml': '',
    '.gitignore': '',
    '.semgrepignore': '',
    '.github/codeql/codeql-config.yml': '',
  });
  assert.deepEqual(
    error.filter((line) => line.includes('.workflows')),
    [
      'Biome (biome.json) does not skip .workflows: add "!!.workflows" to files.includes',
      'tsc (tsconfig.json) does not skip .workflows: add ".workflows" to exclude',
      'knip (knip.json) does not skip .workflows: add ".workflows/**" to ignore, or keep every entry and project glob out of dot directories',
      'typos (typos.toml) does not skip .workflows: add ".workflows/" to [files] extend-exclude',
      'git (.gitignore) does not skip .workflows: add /.workflows/',
    ],
  );
});

test('Semgrep counts the package list: the default pair needs no line of the app, another directory does', () => {
  const files = { ...ALIGNED, '.semgrepignore': '# nothing of its own\n' };
  assert.equal(run(files).code, 0);
  const semgrep = (argv) => run(files, { argv }).error.filter((line) => line.startsWith('Semgrep'));
  assert.deepEqual(semgrep(['--directory', 'generated']), ['Semgrep (.semgrepignore) does not skip generated: add generated/']);
  assert.deepEqual(semgrep(['--directory', 'node_modules']), []);
});

test('CodeQL counts the package defaults, so only a directory they do not name needs the app\'s own entry', () => {
  const files = { ...ALIGNED, '.github/codeql/codeql-config.yml': 'paths-ignore:\n  - src/generated\n' };
  assert.equal(run(files).code, 0);
  const codeql = (argv) => run(files, { argv }).error.filter((line) => line.startsWith('CodeQL'));
  assert.deepEqual(codeql(['--directory', 'vendor']), ['CodeQL (.github/codeql/codeql-config.yml) does not skip vendor: add "- vendor" to paths-ignore']);
  assert.deepEqual(codeql(['--directory', 'src/generated']), []);
  assert.deepEqual(codeql(['--directory', 'ios']), []);
});

test('main passes a repository whose every configuration skips both, and names what it checked', () => {
  assert.deepEqual(run(ALIGNED), {
    code: 0,
    log: ['ignored directories ok (.workflows, .claude/worktrees; Biome, tsc, knip, typos, git, zizmor)'],
    error: [],
  });
});

test('main names each configuration that misses a directory, with the fix', () => {
  const { code, error } = run({ ...ALIGNED, '.semgrepignore': '.claude/worktrees/\n', 'tsconfig.json': '{"exclude":[]}' }, { calls: ['Makefile:1:zizmor --offline .'] });
  assert.equal(code, 1);
  assert.deepEqual(error, [
    'tsc (tsconfig.json) does not skip .workflows: add ".workflows" to exclude',
    'tsc (tsconfig.json) does not skip .claude/worktrees: add ".claude/worktrees" to exclude',
    'zizmor is called without --config: Makefile:1:zizmor --offline .',
    'ignored directories: 3 problem(s)',
  ]);
});

describe('Biome extends', () => {
  const PRESET = '{"files":{"includes":["**","!**/.workflows","!!.claude/worktrees"]}}';
  const reader = (files) => (file) => {
    if (!(file in files)) throw new Error(`ENOENT: ${file}`);
    return files[file];
  };
  const resolve = (specifier) => `/r/node_modules/${specifier}.json`;

  test('a preset the configuration extends counts, base first, ahead of its own entries', () => {
    const config = biomeExtends({ extends: ['@scope/preset'], files: { includes: ['!src/generated'] } }, '/r/biome.json', {
      read: reader({ '/r/node_modules/@scope/preset.json': PRESET }),
      resolve,
    });
    assert.deepEqual(config.files.includes, ['**', '!**/.workflows', '!!.claude/worktrees', '!src/generated']);
    assert.deepEqual(config.files.ignore, []);
  });

  test('a relative extends is read from the configuration directory, its own extends followed, a cycle read once', () => {
    const config = biomeExtends({ extends: './base.json' }, '/r/biome.json', {
      read: reader({
        '/r/base.json': '{"extends":["./biome.json","./older.json"],"files":{"includes":["!!.claude/worktrees"]}}',
        '/r/older.json': '{"files":{"ignore":[".workflows"]}}',
      }),
      resolve,
    });
    assert.deepEqual(config.files.includes, ['!!.claude/worktrees']);
    assert.deepEqual(config.files.ignore, ['.workflows']);
  });

  test('the monorepo root "//" has no file to read and is left out', () => {
    const config = biomeExtends({ extends: ['//'] }, '/r/biome.json', { read: reader({}), resolve });
    assert.deepEqual(config.files, { includes: [], ignore: [] });
  });

  test('main passes an app whose biome.json skips both only through the preset it extends', () => {
    const { code, error } = run({ ...ALIGNED, 'biome.json': '{"extends":["@scope/preset"]}', 'node_modules/@scope/preset.json': PRESET });
    assert.equal(code, 0, error.join('\n'));
  });

  test('main reports an extends it cannot read', () => {
    const { code, error } = run({ ...ALIGNED, 'biome.json': '{"extends":["@scope/missing"]}' });
    assert.equal(code, 1);
    assert.match(error[0], /^Biome \(biome\.json\) could not be read: ENOENT: .*@scope\/missing\.json$/);
  });

  test('main resolves a package preset through the repository node_modules, package exports included', () => {
    const root = path.join(work, 'biome-extends');
    const pkg = path.join(root, 'node_modules', '@scope', 'preset');
    mkdirSync(pkg, { recursive: true });
    writeFileSync(path.join(pkg, 'package.json'), JSON.stringify({ name: '@scope/preset', exports: { './biome': './biome.json' } }));
    writeFileSync(path.join(pkg, 'biome.json'), PRESET);
    writeFileSync(path.join(root, 'biome.json'), '{"extends":["@scope/preset/biome"]}');
    const out = [];
    const code = main(['--root', root], { cwd: root, grep: () => [], log: (line) => out.push(line), error: (line) => out.push(line) });
    assert.equal(code, 0, out.join('\n'));
    assert.deepEqual(out, ['ignored directories ok (.workflows, .claude/worktrees; Biome, zizmor)']);
  });
});

test('main reports a configuration it cannot parse, or a tool it cannot load, as a problem', () => {
  const { code, error } = run({ 'biome.json': '{', 'jest.config.ts': '' }, { loaded: { jest: new Error('Cannot find module jest\nstack') }, calls: new Error('not a git repository') });
  assert.equal(code, 1);
  assert.match(error[0], /^Biome \(biome\.json\) could not be read: /);
  assert.equal(error[1], 'Jest (jest.config.ts) could not be read: Cannot find module jest');
  assert.equal(error[2], 'zizmor (git grep) could not be read: not a git repository');
});

test('main asks Jest, Metro and ESLint through their own configurations', () => {
  const both = ['<rootDir>/\\.workflows/', '<rootDir>/\\.claude/worktrees/'];
  const seen = [];
  const { code, log, error } = run(
    { 'jest.config.ts': '', 'metro.config.js': '', 'eslint.config.mjs': '' },
    {
      loaded: {
        jest: (args) => {
          seen.push(args);
          return { testPathIgnorePatterns: both, modulePathIgnorePatterns: both, coveragePathIgnorePatterns: both };
        },
        metro: () => [['^(?:\\/r\\/)?(?:\\.workflows|\\.claude[\\\\/]worktrees)(?:[\\\\/]|$)', '']],
        eslint: (args) => {
          seen.push(args);
          return [false, true, true];
        },
      },
    },
  );
  assert.deepEqual({ code, error }, { code: 0, error: [] });
  assert.deepEqual(log, ['ignored directories ok (.workflows, .claude/worktrees; Jest, Metro, ESLint, zizmor)']);
  assert.deepEqual(seen, [['/r/jest.config.ts'], ['/r', JSON.stringify(['/r/probe.mjs', '/r/.workflows/probe/probe.mjs', '/r/.claude/worktrees/probe/probe.mjs'])]]);
});

test('main names what ESLint and Metro get wrong', () => {
  const { code, error } = run({ 'metro.config.js': '', 'eslint.config.mjs': '' }, { loaded: { metro: [], eslint: [true, false, true] } });
  assert.equal(code, 1);
  assert.deepEqual(error, [
    "Metro's resolver.blockList does not block .workflows",
    "Metro's resolver.blockList does not block .claude/worktrees",
    "ESLint (eslint.config.mjs) ignores this checkout's own files",
    "ESLint (eslint.config.mjs) does not ignore .workflows: add '.workflows/**' to the ignores",
    'ignored directories: 4 problem(s)',
  ]);
});

test('main refuses a bad argument', () => {
  assert.deepEqual(run({}, { argv: ['--nope'] }).error, ['ignored directories: unexpected --nope: pass --root DIR, --directory RELATIVE-DIR and --worktrees RELATIVE-DIR']);
});

describe('loading the real configurations in a child process', () => {
  let repo;
  before(() => {
    repo = mkdtempSync(path.join(work, 'repo-'));
    writeFileSync(path.join(repo, 'package.json'), '{"name":"fixture"}');
    writeFileSync(path.join(repo, '.gitignore'), '/.workflows/\n');
    writeFileSync(
      path.join(repo, 'jest.config.mjs'),
      "export default async () => ({ testPathIgnorePatterns: ['<rootDir>/\\\\.workflows/'] });\n",
    );
    writeFileSync(path.join(repo, 'metro.config.js'), "module.exports = Promise.resolve({ resolver: { blockList: /\\.workflows/i } });\n");
    writeFileSync(path.join(repo, 'metro.config.mjs'), 'export default () => ({ resolver: {} });\n');
    mkdirSync(path.join(repo, 'node_modules', 'eslint'), { recursive: true });
    writeFileSync(path.join(repo, 'node_modules', 'eslint', 'package.json'), '{"name":"eslint","main":"index.js"}');
    writeFileSync(
      path.join(repo, 'node_modules', 'eslint', 'index.js'),
      'class ESLint { constructor({ cwd }) { this.cwd = cwd; } async isPathIgnored(file) { return file.startsWith(this.cwd + "/.workflows/"); } }\nmodule.exports = { ESLint };\n',
    );
  });

  test('evaluate loads a Jest configuration, calling one that is a function', () => {
    const code = `const { pathToFileURL } = await import('node:url');
const loaded = await import(pathToFileURL(process.argv[1]).href);
let config = loaded.default ?? loaded;
if (typeof config === 'function') config = await config();
console.log(JSON.stringify(config));`;
    assert.deepEqual(evaluate(code, [path.join(repo, 'jest.config.mjs')], repo), { testPathIgnorePatterns: ['<rootDir>/\\.workflows/'] });
  });

  test('main loads Jest, Metro (CommonJS or an ES module) and the installed ESLint', () => {
    const out = [];
    const code = main(['--root', repo, '--directory', '.workflows'], { log: (l) => out.push(l), error: (l) => out.push(l), grep: () => [] });
    assert.equal(code, 1);
    assert.deepEqual(out, [
      "Jest (project 1) modulePathIgnorePatterns does not skip .workflows: add '<rootDir>/\\\\.workflows/'",
      "Jest (project 1) coveragePathIgnorePatterns does not skip .workflows: add '<rootDir>/\\\\.workflows/'",
      "Metro's resolver.blockList blocks .workflows-notes too: end the .workflows pattern at a separator",
      'ignored directories: 3 problem(s)',
    ]);
    rmSync(path.join(repo, 'metro.config.js'));
    const esm = [];
    main(['--root', repo, '--directory', '.workflows'], { log: (l) => esm.push(l), error: (l) => esm.push(l), grep: () => [] });
    assert.ok(esm.includes("Metro's resolver.blockList does not block .workflows"), esm.join('\n'));
  });

  test('as a command it reads --root', () => {
    const empty = mkdtempSync(path.join(work, 'empty-'));
    const env = { ...clean(), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CEILING_DIRECTORIES: work };
    execFileSync('git', ['init', '-q'], { cwd: empty, env });
    const result = spawnSync(process.execPath, [BIN, '--root', empty], { encoding: 'utf8', env });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'ignored directories ok (.workflows, .claude/worktrees; zizmor)\n');
  });
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line) });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +check-ignored-directories(?: |$)/m);
  assert.deepEqual(err, []);
});
