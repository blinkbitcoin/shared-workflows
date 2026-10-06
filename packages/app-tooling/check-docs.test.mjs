// check-docs run in-process inside throwaway git repositories. git is the real
// one, wrapped so each case can record the calls and refuse a fetch, which
// makes every step of the fetch fallback reachable without a network; the
// origin is a bare repository on disk. The three programs it hands over to are
// replaced by a recorder that fails on request.
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { freshness, main, parseArgs, runGit, runProgram, tableProblems, withConfig } from './bin/check-docs.mjs';

const BIN = fileURLToPath(new URL('./bin/check-docs.mjs', import.meta.url));
let work;

const MAKEFILE = `.PHONY: help dev gen-i18n internal

help: ## Show every target
\t@true

dev: ## Metro for the dev client
\t@true

gen-i18n: ## Extract and compile the catalogs
\t@true

internal:
\t@true
`;

const AGENTS = `# Agent guide

| Command | |
|---|---|
| \`make help\` | Show every target |
| \`make dev\` | Metro |
| \`make gen-i18n\` | Catalogs |

Prose may name \`make internal\`, a target that exists but has no \`##\` description.
`;

// The template's architecture paths and its one target-name exception.
const ALLOW = 'gen-graphql=GraphQL is what it generates, the typed documents, not the tool that does it';
const ARGV = [
  '--architecture', 'app.config.ts',
  '--architecture', 'plugins/',
  '--architecture', 'modules/',
  '--architecture', 'src/graphql/',
  '--architecture', 'scripts/',
  '--architecture', 'Makefile',
  '--allow-target-name', ALLOW,
];
const PROGRAMS = [`check-make-target-names --allow ${ALLOW}`, 'check-docs-tables', 'check-diagrams'];
const ADVISORY = 'warning: architecture-relevant changes without a docs/ update:';

// Git itself, without the machine's configuration and without any repository
// a hook or a parent directory would otherwise point it at.
const gitEnv = () => {
  const env = { ...process.env };
  for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
  for (const key of ['CI', 'GITHUB_ACTIONS', 'EVENT_NAME', 'BASE_REF', 'PR_AUTHOR']) delete env[key];
  return {
    ...env,
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_AUTHOR_NAME: 'Test',
    GIT_AUTHOR_EMAIL: 'test@example.com',
    GIT_COMMITTER_NAME: 'Test',
    GIT_COMMITTER_EMAIL: 'test@example.com',
    GIT_CEILING_DIRECTORIES: work,
  };
};
const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8', env: gitEnv() }).trim();

before(() => {
  work = mkdtempSync(path.join(tmpdir(), 'check-docs-'));
});
after(() => {
  rmSync(work, { recursive: true, force: true });
});

function write(root, files) {
  for (const [rel, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    writeFileSync(path.join(root, rel), text);
  }
}

/** A plain directory holding the Makefile and AGENTS.md: no git at all. */
function tree({ makefile = MAKEFILE, agents = AGENTS } = {}) {
  const dir = mkdtempSync(path.join(work, 'case-'));
  const repo = path.join(dir, 'repo');
  mkdirSync(repo);
  write(repo, { Makefile: makefile, 'README.md': '# fixture\n' });
  if (agents !== null) write(repo, { 'AGENTS.md': agents });
  return { dir, repo };
}

/** The same tree as a repository with one commit on main, pushed to a bare origin unless `remote` is false. */
function repository({ remote = true } = {}) {
  const fx = tree();
  git(fx.repo, 'init', '-q', '-b', 'main');
  git(fx.repo, 'add', '-A');
  git(fx.repo, 'commit', '-q', '-m', 'base');
  fx.base = git(fx.repo, 'rev-parse', 'HEAD');
  if (remote) {
    fx.origin = path.join(fx.dir, 'origin.git');
    git(fx.dir, 'init', '-q', '--bare', '-b', 'main', fx.origin);
    git(fx.repo, 'remote', 'add', 'origin', fx.origin);
    git(fx.repo, 'push', '-q', 'origin', 'main');
  }
  return fx;
}

function commit(fx, files, message = 'change') {
  write(fx.repo, files);
  git(fx.repo, 'add', '-A');
  git(fx.repo, 'commit', '-q', '-m', message);
}

/** A feature branch off main carrying `files`, as a pull request would. */
function feature(files, options) {
  const fx = repository(options);
  git(fx.repo, 'checkout', '-q', '-b', 'feature');
  commit(fx, files);
  return fx;
}

/**
 * main over the fixture. `env` is CI's; `fail` names a program to fail with
 * status 7; `failFetch` refuses every fetch, `failDeepen` only a deepening one.
 */
function run(fx, { env = {}, fail, failFetch = false, failDeepen = false, argv = ARGV } = {}) {
  const calls = { git: [], programs: [] };
  const out = { stdout: [], stderr: [] };
  const status = main(['--root', fx.repo, ...argv], {
    cwd: fx.dir,
    env: { ...gitEnv(), ...env },
    log: (line) => out.stdout.push(line),
    error: (line) => out.stderr.push(line),
    git: (args, options) => {
      calls.git.push(args.join(' '));
      if (args[0] === 'fetch' && (failFetch || (failDeepen && args.includes('--deepen=50')))) return { status: 1, stdout: '' };
      return runGit(args, options);
    },
    program: (name, args, options) => {
      assert.equal(options.cwd, fx.repo);
      calls.programs.push([name, ...args].join(' '));
      return name === fail ? 7 : 0;
    },
  });
  return { status, stdout: out.stdout.join('\n'), stderr: out.stderr.map((l) => `${l}\n`).join(''), ...calls };
}

/** The paths the advisory listed, or null when it did not fire. */
function advised(stderr) {
  const lines = stderr.split('\n');
  const at = lines.indexOf(ADVISORY);
  if (at === -1) return null;
  const listed = [];
  for (const line of lines.slice(at + 1)) {
    if (!line.startsWith('  ')) break;
    listed.push(line.slice(2));
  }
  return listed.sort();
}

function assertPassed(result) {
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'docs check ok');
}

describe('1. the docs freshness advisory', () => {
  test('an architecture change without a docs/ change is warned about, and the check still passes', () => {
    const result = run(feature({ 'scripts/new.sh': 'echo\n' }));
    assertPassed(result);
    assert.deepEqual(advised(result.stderr), ['scripts/new.sh']);
    assert.equal(result.git.some((line) => line.startsWith('show')), false, 'no manifest changed, so none is read');
  });

  test('every architecture-relevant path is listed, and nothing else', () => {
    const result = run(
      feature({
        'app.config.ts': 'export default {};\n',
        'plugins/with-thing.ts': '',
        'modules/hello/index.ts': '',
        'src/graphql/client.ts': '',
        'scripts/tool.mjs': '',
        Makefile: `${MAKEFILE}# a comment\n`,
        'src/features/home/Home.tsx': '',
        'src/graphql-notes.md': '',
        'README.md': '# changed\n',
      }),
    );
    assertPassed(result);
    assert.deepEqual(advised(result.stderr), [
      'Makefile',
      'app.config.ts',
      'modules/hello/index.ts',
      'plugins/with-thing.ts',
      'scripts/tool.mjs',
      'src/graphql/client.ts',
    ]);
  });

  test('an architecture change that also touches docs/ is not warned about', () => {
    const result = run(feature({ 'plugins/with-thing.ts': '', 'docs/architecture.md': '# updated\n' }));
    assertPassed(result);
    assert.equal(result.stderr, '');
  });

  test('--docs names where the docs live', () => {
    const result = run(feature({ 'plugins/with-thing.ts': '', 'handbook/a.md': '# updated\n' }), {
      argv: [...ARGV, '--docs', 'handbook/'],
    });
    assertPassed(result);
    assert.equal(result.stderr, '');
    const elsewhere = run(feature({ 'plugins/with-thing.ts': '' }), { argv: [...ARGV, '--docs', 'handbook/'] });
    assert.match(elsewhere.stderr, /^warning: architecture-relevant changes without a handbook\/ update:$/m);
  });

  test('a change to nothing architecture-relevant is not warned about', () => {
    const result = run(feature({ 'src/features/home/Home.tsx': '', 'README.md': '# changed\n' }));
    assertPassed(result);
    assert.equal(result.stderr, '');
  });

  test('with no --architecture only a structural manifest is architecture', () => {
    const result = run(feature({ 'scripts/tool.mjs': '' }), { argv: [] });
    assertPassed(result);
    assert.equal(result.stderr, '');
  });

  test('a Dependabot pull request is never expected to touch docs/', () => {
    const result = run(feature({ 'scripts/tool.mjs': '' }), { env: { PR_AUTHOR: 'dependabot[bot]' } });
    assertPassed(result);
    assert.equal(result.stderr, '');
  });

  test('a structural package.json change joins the list, read at the merge base', () => {
    const fx = feature({ 'package.json': '{"scripts":{}}\n', 'mocks/package.json': '{}\n' });
    const result = run(fx);
    assertPassed(result);
    assert.deepEqual(
      result.git.filter((line) => line.startsWith('show')),
      [],
      'the manifests are read through readAtRef, not the recorded runner',
    );
    assert.deepEqual(advised(result.stderr), ['mocks/package.json', 'package.json']);
  });

  test('a dependency-only package.json change is not warned about', () => {
    const fx = repository();
    commit(fx, { 'package.json': '{"name":"app","dependencies":{"a":"1"}}\n' });
    git(fx.repo, 'push', '-q', 'origin', 'main');
    git(fx.repo, 'checkout', '-q', '-b', 'feature');
    commit(fx, { 'package.json': '{"name":"app","dependencies":{"a":"2"}}\n' });
    const result = run(fx);
    assertPassed(result);
    assert.equal(result.stderr, '');
  });

  test('a structural manifest adds to the other architecture paths rather than replacing them', () => {
    const result = run(feature({ 'package.json': '{}\n', 'plugins/with-thing.ts': '' }));
    assertPassed(result);
    assert.deepEqual(advised(result.stderr), ['package.json', 'plugins/with-thing.ts']);
  });
});

describe('resolving the base, and failing open when it cannot', () => {
  test('outside a repository the advisory skips quietly', () => {
    const result = run(tree());
    assertPassed(result);
    assert.equal(result.stderr, '');
  });

  test('a repository with no remote skips quietly: origin/main can never resolve there', () => {
    const fx = repository({ remote: false });
    commit(fx, { 'scripts/tool.mjs': '' });
    const result = run(fx);
    assertPassed(result);
    assert.equal(result.stderr, '');
    assert.equal(result.git.some((line) => line.startsWith('fetch')), false, 'a local run never fetches');
  });

  test('an unresolvable base with a remote is skipped out loud', () => {
    const fx = feature({ 'scripts/tool.mjs': '' });
    git(fx.repo, 'update-ref', '-d', 'refs/remotes/origin/main');
    const result = run(fx);
    assertPassed(result);
    assert.equal(result.stderr, 'notice: docs freshness skipped: cannot resolve origin/main (a shallow clone that does not reach it)\n');
  });

  test('--default-branch names the base a laptop compares with', () => {
    const fx = feature({ 'scripts/tool.mjs': '' });
    const result = run(fx, { argv: [...ARGV, '--default-branch', 'trunk'] });
    assert.equal(result.stderr, 'notice: docs freshness skipped: cannot resolve origin/trunk (a shallow clone that does not reach it)\n');
  });

  test('under CI the skip is a ::notice:: annotation', () => {
    const fx = feature({ 'scripts/tool.mjs': '' });
    git(fx.repo, 'update-ref', '-d', 'refs/remotes/origin/main');
    const result = run(fx, { env: { CI: 'true' } });
    assertPassed(result);
    assert.equal(result.stderr, '::notice::docs freshness skipped: cannot resolve origin/main (a shallow clone that does not reach it)\n');
  });

  test('no merge base even after one unshallow is skipped out loud', () => {
    const fx = feature({ 'scripts/tool.mjs': '' });
    // origin/main moves to a history HEAD shares nothing with.
    git(fx.repo, 'checkout', '-q', '--orphan', 'unrelated');
    commit(fx, { 'other.txt': 'x\n' }, 'unrelated root');
    git(fx.repo, 'push', '-q', '-f', 'origin', 'unrelated:main');
    git(fx.repo, 'checkout', '-q', 'feature');
    const result = run(fx);
    assertPassed(result);
    assert.ok(result.git.includes('fetch -q --no-tags --unshallow origin'), result.git.join('\n'));
    assert.equal(result.stderr, 'notice: docs freshness skipped: no merge base between origin/main and HEAD\n');
  });

  test('a shallow clone that cannot reach the merge base is unshallowed once, then checked', () => {
    // origin: base, then main moves on; feature branches off base.
    const upstream = repository();
    git(upstream.repo, 'checkout', '-q', '-b', 'feature');
    commit(upstream, { 'scripts/tool.mjs': '' });
    git(upstream.repo, 'push', '-q', 'origin', 'feature');
    git(upstream.repo, 'checkout', '-q', 'main');
    commit(upstream, { 'src/features/home/Home.tsx': '' }, 'main moves on');
    git(upstream.repo, 'push', '-q', 'origin', 'main');

    const fx = { dir: upstream.dir, repo: path.join(upstream.dir, 'shallow') };
    git(upstream.dir, 'clone', '-q', '--depth=1', '--no-single-branch', '--branch', 'feature', `file://${upstream.origin}`, fx.repo);
    assert.throws(() => git(fx.repo, 'merge-base', 'origin/main', 'HEAD'), 'the fixture must start shallow');
    const result = run(fx);
    assertPassed(result);
    assert.ok(result.git.includes('fetch -q --no-tags --unshallow origin'), result.git.join('\n'));
    assert.deepEqual(advised(result.stderr), ['scripts/tool.mjs']);
  });

  test('a pull request fetches its base branch into origin/<base> and diffs against it', () => {
    const fx = feature({ 'scripts/tool.mjs': '' });
    // A single-branch CI checkout has no origin/main until the check names it.
    git(fx.repo, 'update-ref', '-d', 'refs/remotes/origin/main');
    const result = run(fx, { env: { EVENT_NAME: 'pull_request', BASE_REF: 'main' } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      result.git.filter((line) => line.startsWith('fetch'))[0],
      'fetch -q --no-tags --deepen=50 origin +refs/heads/main:refs/remotes/origin/main',
    );
    assert.deepEqual(advised(result.stderr), ['scripts/tool.mjs']);
    assert.equal(result.programs.at(-1), 'check-diagrams --all');
  });

  test('when --deepen is refused the pull request falls back to a plain fetch of the same refspec', () => {
    const fx = feature({ 'scripts/tool.mjs': '' });
    git(fx.repo, 'update-ref', '-d', 'refs/remotes/origin/main');
    const result = run(fx, { env: { EVENT_NAME: 'pull_request', BASE_REF: 'main' }, failDeepen: true });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(
      result.git.filter((line) => line.startsWith('fetch')),
      [
        'fetch -q --no-tags --deepen=50 origin +refs/heads/main:refs/remotes/origin/main',
        'fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main',
      ],
    );
    assert.deepEqual(advised(result.stderr), ['scripts/tool.mjs']);
  });

  test('a push diffs HEAD against HEAD~1, not origin/main (which is HEAD itself on main)', () => {
    const fx = repository();
    commit(fx, { 'scripts/tool.mjs': '' });
    git(fx.repo, 'push', '-q', 'origin', 'main');
    const result = run(fx, { env: { EVENT_NAME: 'push' } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.git.filter((line) => line.startsWith('fetch'))[0], 'fetch -q --no-tags --deepen=50 origin');
    assert.deepEqual(advised(result.stderr), ['scripts/tool.mjs']);
  });

  test('a pull request event without a base branch is treated like a push', () => {
    const fx = repository();
    commit(fx, { 'scripts/tool.mjs': '' });
    git(fx.repo, 'push', '-q', 'origin', 'main');
    const result = run(fx, { env: { EVENT_NAME: 'pull_request', BASE_REF: '' } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.git.filter((line) => line.startsWith('fetch'))[0], 'fetch -q --no-tags --deepen=50 origin');
    assert.deepEqual(advised(result.stderr), ['scripts/tool.mjs']);
  });

  test('fetches that all fail are not an error: the advisory works with what is there', () => {
    const fx = repository();
    commit(fx, { 'scripts/tool.mjs': '' });
    const result = run(fx, { env: { EVENT_NAME: 'push' }, failFetch: true });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.git.filter((line) => line.startsWith('fetch')), ['fetch -q --no-tags --deepen=50 origin', 'fetch -q --no-tags origin']);
    assert.deepEqual(advised(result.stderr), ['scripts/tool.mjs']);
  });

  test('a git that cannot start reads as a failure, not as output', () => {
    const fx = tree();
    assert.deepEqual(runGit(['status'], { cwd: fx.repo, env: { ...gitEnv(), PATH: fx.dir } }), { status: null, stdout: undefined });
  });

  test('a diff git cannot produce reads as no change', () => {
    const lines = freshness(
      { architecture: ['scripts/'], docs: 'docs/', defaultBranch: 'main' },
      {
        env: {},
        git: (args) => (args[0] === 'diff' ? { status: 128, stdout: '' } : { status: 0, stdout: 'abc\n' }),
        readAt: () => undefined,
        readNow: () => undefined,
      },
    );
    assert.deepEqual(lines, []);
  });
});

describe('2. the command table against the Makefile, both directions', () => {
  test('agreeing passes, then runs the three programs', () => {
    const result = run(tree());
    assertPassed(result);
    assert.deepEqual(result.programs, PROGRAMS);
  });

  test('a missing AGENTS.md fails before any other check', () => {
    const result = run(tree({ agents: null }));
    assert.equal(result.status, 1);
    assert.equal(result.stderr, 'AGENTS.md is missing: the command table is the agent-facing contract\n');
    assert.deepEqual(result.programs, []);
  });

  test('--agents names another file', () => {
    const fx = tree({ agents: null });
    write(fx.repo, { 'CONTRIBUTING.md': AGENTS });
    assertPassed(run(fx, { argv: ['--agents', 'CONTRIBUTING.md'] }));
    const missing = run(fx, { argv: ['--agents', 'GUIDE.md'] });
    assert.equal(missing.stderr, 'GUIDE.md is missing: the command table is the agent-facing contract\n');
  });

  test('a missing Makefile fails', () => {
    const fx = tree();
    rmSync(path.join(fx.repo, 'Makefile'));
    const result = run(fx);
    assert.equal(result.status, 1);
    assert.equal(result.stderr, `docs check: no Makefile in ${fx.repo}\n`);
  });

  test('a documented make target without a table row fails', () => {
    const result = run(tree({ makefile: `${MAKEFILE}\nbuild-web: deps ## Static web export\n\t@true\n` }));
    assert.equal(result.status, 1);
    assert.equal(
      result.stderr,
      'AGENTS.md is missing a command-table row for make target: build-web\nAGENTS.md and the Makefile disagree; update whichever is wrong\n',
    );
    assert.deepEqual(result.programs, []);
  });

  test('a target in an included fragment needs its row too', () => {
    const fx = tree({ makefile: `include make/extra.mk\n${MAKEFILE}` });
    write(fx.repo, { 'make/extra.mk': 'check-extra: ## Extra\n\t@true\n' });
    assert.match(run(fx).stderr, /missing a command-table row for make target: check-extra\n/);
  });

  test('a table row for a make target that does not exist fails', () => {
    const result = run(tree({ agents: `${AGENTS}| \`make ghost\` | Gone |\n` }));
    assert.equal(result.status, 1);
    assert.equal(result.stderr, 'AGENTS.md references missing make target: ghost\nAGENTS.md and the Makefile disagree; update whichever is wrong\n');
    assert.deepEqual(result.programs, []);
  });

  test('both directions are reported in one run', () => {
    const result = run(
      tree({ makefile: `${MAKEFILE}\ntest-e2e-ios: ## Maestro flows\n\t@true\n`, agents: `${AGENTS}| \`make ghost\` | Gone |\n` }),
    );
    assert.equal(result.status, 1);
    assert.match(result.stderr, /missing a command-table row for make target: test-e2e-ios\n/);
    assert.match(result.stderr, /references missing make target: ghost\n/);
  });

  test('tableProblems reads an assignment as no rule', () => {
    assert.deepEqual(tableProblems('VAR:= x\n', '`make VAR`', 'AGENTS.md'), []);
    assert.deepEqual(tableProblems('var:= x\n', '`make var`', 'AGENTS.md'), ['AGENTS.md references missing make target: var']);
  });
});

describe('3-5. the app-tooling programs', () => {
  test('under CI every diagram is checked, not only the changed ones', () => {
    const result = run(tree(), { env: { EVENT_NAME: 'push' } });
    assertPassed(result);
    assert.deepEqual(result.programs, [...PROGRAMS.slice(0, 2), 'check-diagrams --all']);
  });

  test('no --allow-target-name runs the target-name check with no exception', () => {
    assert.deepEqual(run(tree(), { argv: [] }).programs, ['check-make-target-names', 'check-docs-tables', 'check-diagrams']);
  });

  for (const [failing, ran] of [
    ['check-make-target-names', 1],
    ['check-docs-tables', 2],
    ['check-diagrams', 3],
  ]) {
    test(`a failing ${failing} fails the check with its status and stops there`, () => {
      const result = run(tree(), { fail: failing });
      assert.equal(result.status, 7);
      assert.equal(result.stdout, '');
      assert.deepEqual(result.programs, PROGRAMS.slice(0, ran));
    });
  }

  test('a program killed by a signal fails the check', () => {
    const fx = tree();
    const status = main([], { cwd: fx.repo, env: gitEnv(), log: () => {}, error: () => {}, program: () => null });
    assert.equal(status, 1);
  });

  test('runProgram runs a sibling program in the directory it is given and returns its status', () => {
    const fx = tree();
    assert.equal(runProgram('help', [], { cwd: fx.repo, env: process.env, stdio: 'ignore' }), 0);
    assert.equal(runProgram('help', ['--nope'], { cwd: fx.repo, env: process.env, stdio: 'ignore' }), 1);
  });
});

describe('app-tooling.json', () => {
  // The template's rules as its app-tooling.json will hold them.
  const FILE = JSON.stringify({
    docs: {
      architecture: ['app.config.ts', 'plugins/', 'modules/', 'src/graphql/', 'scripts/', 'Makefile'],
      allowTargetNames: { 'gen-graphql': 'GraphQL is what it generates, the typed documents, not the tool that does it' },
    },
    testSiblings: {},
  });

  test('with no flags the rules come from the file, and do what the flags did', () => {
    const fx = feature({ 'scripts/new.sh': 'echo\n' });
    write(fx.repo, { 'app-tooling.json': FILE });
    const fromFile = run(fx, { argv: [] });
    assertPassed(fromFile);
    assert.deepEqual(advised(fromFile.stderr), ['scripts/new.sh']);
    assert.deepEqual(fromFile.programs, PROGRAMS);
  });

  test('a flag overrides its own field of the file, and leaves the other', () => {
    const fx = feature({ 'scripts/new.sh': 'echo\n', 'lib/a.mjs': '' });
    write(fx.repo, { 'app-tooling.json': FILE });
    const result = run(fx, { argv: ['--architecture', 'lib/'] });
    assert.deepEqual(advised(result.stderr), ['lib/a.mjs']);
    assert.deepEqual(result.programs, PROGRAMS);
    const allow = run(fx, { argv: ['--allow-target-name', 'x=y'] });
    assert.deepEqual(advised(allow.stderr), ['scripts/new.sh']);
    assert.equal(allow.programs[0], 'check-make-target-names --allow x=y');
  });

  test('withConfig leaves the options alone when there is no section, and reads an empty one as no rules', () => {
    const options = parseArgs([], '/w');
    assert.equal(withConfig(options, null), options);
    assert.deepEqual(withConfig(options, {}), options);
  });

  for (const [what, file, reason] of [
    ['invalid JSON', '{', /^docs check: app-tooling\.json: not valid JSON: /],
    ['an unknown key', '{"docs":{"paths":[]}}', /^docs check: app-tooling\.json: unknown key "docs\.paths"/],
    ['architecture that is not a list', '{"docs":{"architecture":"scripts/"}}', /"docs\.architecture" must be a list of non-empty strings/],
    ['exceptions that are a list', '{"docs":{"allowTargetNames":["gen-graphql=x"]}}', /"docs\.allowTargetNames" must be an object of non-empty strings/],
    ['an exception with no reason', '{"docs":{"allowTargetNames":{"gen-graphql":""}}}', /"docs\.allowTargetNames" must be an object of non-empty strings/],
    ['an exception that is not a target', '{"docs":{"allowTargetNames":{"gen graphql":"x"}}}', /"docs\.allowTargetNames" names "gen graphql", which is not a make target/],
  ]) {
    test(`a file with ${what} exits 2 with the reason, before any check runs`, () => {
      const fx = tree();
      write(fx.repo, { 'app-tooling.json': file });
      const result = run(fx, { argv: [] });
      assert.equal(result.status, 2);
      assert.match(result.stderr, reason);
      assert.deepEqual(result.git, []);
      assert.deepEqual(result.programs, []);
    });
  }
});

test('parseArgs reads every option, and refuses anything else', () => {
  assert.deepEqual(parseArgs([], '/w'), {
    root: '/w',
    architecture: [],
    docs: 'docs/',
    agents: 'AGENTS.md',
    defaultBranch: 'main',
    allowTargetNames: [],
  });
  assert.deepEqual(
    parseArgs(['--root', 'app', '--architecture', 'src/', '--docs', 'handbook/', '--agents', 'GUIDE.md', '--default-branch', 'trunk', '--allow-target-name', 'a=b'], '/w'),
    { root: path.resolve('/w', 'app'), architecture: ['src/'], docs: 'handbook/', agents: 'GUIDE.md', defaultBranch: 'trunk', allowTargetNames: ['a=b'] },
  );
  for (const bad of [['--allow-target-name', 'a='], ['--allow-target-name'], ['--architecture'], ['--nope', 'x']]) {
    assert.throws(() => parseArgs(bad, '/w'), /unexpected .*: pass --root DIR, --architecture PREFIX/, bad.join(' '));
  }
  const out = [];
  assert.equal(main(['--nope'], { error: (line) => out.push(line) }), 1);
  assert.match(out[0], /^docs check: unexpected --nope: /);
});

test('as a command it runs from --root, outside any repository', () => {
  const fx = tree({ agents: null });
  const result = spawnSync(process.execPath, [BIN, '--root', fx.repo], { encoding: 'utf8', env: gitEnv() });
  assert.equal(result.status, 1);
  assert.equal(result.stderr, 'AGENTS.md is missing: the command table is the agent-facing contract\n');
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line) });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +check-docs(?: |$)/m);
  assert.deepEqual(err, []);
});
