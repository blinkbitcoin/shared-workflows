#!/usr/bin/env node
// The docs check a repository on the baseline runs as `make check-docs`.
//
//   check-docs [--root DIR] [--architecture PREFIX ...] [--docs PREFIX]
//              [--agents FILE] [--default-branch NAME] [--allow-target-name TARGET=REASON ...]
//
// Five checks, in this order:
//
//   1. Advisory (a warning, never a failure): paths under an --architecture
//      prefix changed against the base without a change under --docs
//      (default `docs/`). A package.json joins them only when the change is
//      structural - scripts, engines, packageManager, expo.install.exclude -
//      and not a dependency or version bump (lib/manifest-structural.mjs); a
//      Dependabot pull request is never expected to touch the docs.
//   2. The command table in --agents (default AGENTS.md) and the Makefile's
//      `##`-documented targets agree in both directions: every documented
//      target has a `make <target>` in the file, and every `make <target>` it
//      names exists. The Makefile's includes are followed.
//   3. check-make-target-names, with each --allow-target-name as its --allow.
//   4. check-docs-tables.
//   5. check-diagrams, over every diagram under CI (EVENT_NAME set) and the
//      changed ones on a laptop.
//
// The architecture paths and the target-name exceptions are the repository's
// own rules, so they usually live in its `app-tooling.json` and the make recipe
// is the bare call:
//
//   "docs": {
//     "architecture": ["app.config.ts", "plugins/", "scripts/", "Makefile"],
//     "allowTargetNames": { "gen-graphql": "GraphQL is what it generates" }
//   }
//
// Any --architecture replaces `architecture`, and any --allow-target-name
// replaces `allowTargetNames`. A file that is there and wrong exits 2.
//
// The environment CI sets: EVENT_NAME, BASE_REF and PR_AUTHOR. A pull request
// is compared with origin/BASE_REF, a push with HEAD~1 (on the default branch
// origin/NAME *is* HEAD), and a laptop with origin/NAME (--default-branch,
// default main). The advisory fails open at every step - an unfetchable base,
// an unreadable range, no remote at all - because a warning that cannot
// compute its diff must not fail a build. It says so (a ::notice:: under CI)
// rather than passing silently, so "no warning" is never mistaken for "nothing
// to warn about"; a repository with no remote, where the base can never
// resolve, stays quiet.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ConfigError, CONFIG_FILE, readSection, stringList, stringMap } from '../lib/config.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { readAtRef, readWorkingCopy, structuralManifests } from '../lib/manifest-structural.mjs';
import { documentedTargets, expandIncludes } from '../lib/makefile.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** The arguments, as `{ root, architecture, docs, agents, defaultBranch, allowTargetNames }`. */
export function parseArgs(argv, cwd) {
  const options = { root: cwd, architecture: [], docs: 'docs/', agents: 'AGENTS.md', defaultBranch: 'main', allowTargetNames: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--root' && value) options.root = path.resolve(cwd, value);
    else if (arg === '--architecture' && value) options.architecture.push(value);
    else if (arg === '--docs' && value) options.docs = value;
    else if (arg === '--agents' && value) options.agents = value;
    else if (arg === '--default-branch' && value) options.defaultBranch = value;
    else if (arg === '--allow-target-name' && /^[a-zA-Z0-9_.-]+=\s*\S/.test(value ?? '')) options.allowTargetNames.push(value);
    else {
      throw new Error(
        `unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --root DIR, --architecture PREFIX, --docs PREFIX, --agents FILE, --default-branch NAME and --allow-target-name TARGET=REASON`,
      );
    }
  }
  return options;
}

/**
 * The options with the `docs` section of the configuration file under each
 * field no flag set, or a ConfigError naming what is wrong with the section.
 */
export function withConfig(options, section) {
  if (section === null) return options;
  const architecture = section.architecture === undefined ? [] : stringList(section.architecture, 'docs.architecture');
  const allowed = section.allowTargetNames === undefined ? {} : stringMap(section.allowTargetNames, 'docs.allowTargetNames');
  for (const target of Object.keys(allowed)) {
    if (!/^[a-zA-Z0-9_.-]+$/.test(target)) throw new ConfigError(`${CONFIG_FILE}: "docs.allowTargetNames" names "${target}", which is not a make target`);
  }
  return {
    ...options,
    architecture: options.architecture.length > 0 ? options.architecture : architecture,
    allowTargetNames:
      options.allowTargetNames.length > 0 ? options.allowTargetNames : Object.entries(allowed).map(([target, reason]) => `${target}=${reason}`),
  };
}

/**
 * git in `cwd`, as `{ status, stdout }`. A git that cannot start has a null
 * status, which every caller reads as a failure before it reads the output.
 */
export function runGit(args, { cwd, env }) {
  const result = spawnSync('git', args, { cwd, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  return { status: result.status, stdout: result.stdout };
}

/** One of this package's programs, run in `cwd` with its output passed through; returns its exit status. */
export function runProgram(name, args, { cwd, env, stdio = 'inherit' }) {
  return spawnSync(process.execPath, [path.join(HERE, `${name}.mjs`), ...args], { cwd, env, stdio }).status;
}

/**
 * The advisory: what it says, one line each (empty when there is nothing to
 * say). `git(args)` runs git in the repository.
 */
export function freshness({ architecture, docs, defaultBranch }, { env, git, readAt, readNow }) {
  const notice = (message) => [env.CI ? `::notice::${message}` : `notice: ${message}`];
  // CI checks out at depth 1, and two depth-1 tips share no ancestor, so the
  // range would be unreadable without a deepen. `--deepen` is an error on a
  // complete clone, hence the plain fetch after it.
  const deepen = (...refspec) => {
    if (git(['fetch', '-q', '--no-tags', '--deepen=50', 'origin', ...refspec]).status === 0) return;
    git(['fetch', '-q', '--no-tags', 'origin', ...refspec]);
  };
  let base = `origin/${defaultBranch}`;
  if (env.EVENT_NAME === 'pull_request' && env.BASE_REF) {
    // A CI checkout is single-branch: `git fetch origin main` there lands in
    // FETCH_HEAD and never creates refs/remotes/origin/main, so the
    // destination is named.
    deepen(`+refs/heads/${env.BASE_REF}:refs/remotes/origin/${env.BASE_REF}`);
    base = `origin/${env.BASE_REF}`;
  } else if (env.EVENT_NAME) {
    deepen();
    base = 'HEAD~1';
  }
  if (git(['rev-parse', '--verify', '-q', base]).status !== 0) {
    const remotes = git(['remote']);
    return remotes.status === 0 && remotes.stdout.trim() !== ''
      ? notice(`docs freshness skipped: cannot resolve ${base} (a shallow clone that does not reach it)`)
      : [];
  }
  const mergeBase = () => {
    const found = git(['merge-base', base, 'HEAD']);
    return found.status === 0 ? found.stdout.trim() : '';
  };
  let from = mergeBase();
  if (from === '') {
    git(['fetch', '-q', '--no-tags', '--unshallow', 'origin']);
    from = mergeBase();
  }
  if (from === '') return notice(`docs freshness skipped: no merge base between ${base} and HEAD`);
  const diff = git(['diff', '--name-only', from, 'HEAD']);
  const changed = diff.status === 0 ? diff.stdout.split('\n').filter(Boolean) : [];
  const manifests = changed.filter((file) => /(^|\/)package\.json$/.test(file));
  const relevant = [
    ...changed.filter((file) => architecture.some((prefix) => file.startsWith(prefix))),
    ...structuralManifests(manifests, (file) => readAt(from, file), readNow),
  ];
  if (env.PR_AUTHOR === 'dependabot[bot]') return [];
  if (relevant.length === 0 || changed.some((file) => file.startsWith(docs))) return [];
  return [`warning: architecture-relevant changes without a ${docs} update:`, ...[...new Set(relevant)].map((file) => `  ${file}`)];
}

/** Where the command table in `agents` and the Makefile disagree, one line each. */
export function tableProblems(makefile, agents, agentsName) {
  const documented = new Set(documentedTargets(makefile).map(({ target }) => target));
  const rules = new Set([...makefile.matchAll(/^([a-zA-Z0-9_.-]+):(?!=)/gm)].map((match) => match[1]));
  const listed = new Set([...agents.matchAll(/`make ([a-z0-9-]+)`/g)].map((match) => match[1]));
  return [
    ...[...documented].sort().filter((target) => !listed.has(target)).map((target) => `${agentsName} is missing a command-table row for make target: ${target}`),
    ...[...listed].sort().filter((target) => !rules.has(target)).map((target) => `${agentsName} references missing make target: ${target}`),
  ];
}

const readOrNull = (file) => {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
};

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    log = console.log,
    error = console.error,
    cwd = process.cwd(),
    env = process.env,
    read = readOrNull,
    git = runGit,
    program = runProgram,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`docs check: ${e.message}`);
    return 1;
  }
  try {
    options = withConfig(options, readSection(options.root, 'docs', read));
  } catch (e) {
    error(`docs check: ${e.message}`);
    return 2;
  }
  const { root, agents: agentsName } = options;
  const inRoot = { cwd: root, env };
  for (const line of freshness(options, {
    env,
    git: (args) => git(args, inRoot),
    readAt: (ref, file) => readAtRef(ref, file, inRoot),
    readNow: (file) => readWorkingCopy(path.join(root, file)),
  })) {
    error(line);
  }

  const agents = read(path.join(root, agentsName));
  if (agents === null) {
    error(`${agentsName} is missing: the command table is the agent-facing contract`);
    return 1;
  }
  const makefile = expandIncludes(path.join(root, 'Makefile'), read, root);
  if (makefile === null) {
    error(`docs check: no Makefile in ${root}`);
    return 1;
  }
  const problems = tableProblems(makefile, agents, agentsName);
  if (problems.length > 0) {
    for (const problem of problems) error(problem);
    error(`${agentsName} and the Makefile disagree; update whichever is wrong`);
    return 1;
  }

  const calls = [
    ['check-make-target-names', options.allowTargetNames.flatMap((allow) => ['--allow', allow])],
    ['check-docs-tables', []],
    ['check-diagrams', env.EVENT_NAME ? ['--all'] : []],
  ];
  for (const [name, args] of calls) {
    const status = program(name, args, inRoot);
    if (status !== 0) return status ?? 1;
  }
  log('docs check ok');
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
