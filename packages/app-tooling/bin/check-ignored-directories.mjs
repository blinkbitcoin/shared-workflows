#!/usr/bin/env node
// Every tool that walks the tree skips the directories that hold someone
// else's files.
//
//   check-ignored-directories [--root DIR] [--directory DIR ...] [--worktrees DIR]
//
// Two such directories sit inside a repository on the baseline. Every CI job
// checks shared-workflows out into `.workflows/`; Claude Code puts whole
// checkouts of the repository, node_modules included, under
// `.claude/worktrees/`. A tool that walks into either lints, type-checks and
// tests files nobody changed: Jest fails with "Invalid hook call" (a second
// React), ESLint with errors from another checkout. `.git/info/exclude` is per
// clone and not every tool reads it, so each configuration names the
// directories itself. --directory replaces the default pair.
//
// Each tool is checked only when its configuration file exists:
//
//   Jest    jest.config.*: test, module and coverage paths under each directory
//           are ignored in every project (a project whose testMatch is rooted
//           in a named directory needs no test path ignore), and no pattern
//           hides this checkout's own files.
//   Metro   metro.config.*: the resolver's blockList blocks each directory, the
//           absolute path and the root-relative one Expo's crawler asks about,
//           and blocks neither this checkout nor a sibling that shares a prefix.
//   ESLint  eslint.config.*: the installed ESLint answers isPathIgnored.
//   Biome   biome.json(c): a negated files.includes entry (`!` or `!!`), its
//           own or one an `extends` file holds (a shared preset).
//   tsc     tsconfig.json: exclude names it, or every include is rooted.
//   knip    knip.json(c): ignore names it, or no entry or project glob starts
//           at a dot directory (knip's globs skip dot directories otherwise).
//   typos   typos.toml: extend-exclude names it.
//   git, Semgrep and CodeQL: .gitignore, .semgrepignore and the CodeQL
//           configuration's paths-ignore name it. Semgrep and CodeQL also count
//           this package's own lists (security/semgrepignore, codeql-config.yml),
//           which every scan applies, so an app names only the directories
//           those lists do not.
//   zizmor  every call in a tracked file passes --config: zizmor looks for its
//           policy at the nearest directory holding a `.git` directory, and a
//           worktree's `.git` is a file, so without it a worktree reads the
//           outer checkout's policy.
//
// Jest and Metro match absolute paths, and a worktree's own root is itself
// under --worktrees (default `.claude/worktrees`), so their patterns for that
// directory must be anchored to the root: an unanchored one ignores every test,
// or the whole app, when run from a worktree. Those two and ESLint are asked
// by behaviour, loading the configuration in a child process from the
// repository's own node_modules, so install dependencies first.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isProgram } from '../lib/is-program.mjs';
import { yamlList } from './check-code-scanning.mjs';

const DEFAULT_DIRECTORIES = ['.workflows', '.claude/worktrees'];
// What check-security's code scan always excludes, whatever the app's own file says.
const PACKAGED_SEMGREPIGNORE = fileURLToPath(new URL('../security/semgrepignore', import.meta.url));
// What every CodeQL run excludes before the app's own paths-ignore is added.
const PACKAGED_CODEQL_CONFIG = fileURLToPath(new URL('../codeql-config.yml', import.meta.url));
const JEST_OPTIONS = ['testPathIgnorePatterns', 'modulePathIgnorePatterns', 'coveragePathIgnorePatterns'];
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The arguments, as `{ root, directories, worktrees }`. */
export function parseArgs(argv, cwd) {
  let root = cwd;
  const directories = [];
  let worktrees = '.claude/worktrees';
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i]?.replace(/\/+$/, '');
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else if (arg === '--directory' && value && !path.isAbsolute(value)) directories.push(value);
    else if (arg === '--worktrees' && value && !path.isAbsolute(value)) worktrees = value;
    else throw new Error(`unexpected ${[arg, argv[i]].filter(Boolean).join(' ')}: pass --root DIR, --directory RELATIVE-DIR and --worktrees RELATIVE-DIR`);
  }
  return { root, directories: directories.length > 0 ? directories : DEFAULT_DIRECTORIES, worktrees };
}

/** Whether a list entry names `directory`: `dir`, `/dir`, `dir/`, `dir/**`, `**\/dir`. */
export function namesDirectory(entry, directory) {
  return new RegExp(`^/?(?:\\*\\*/)?${escape(directory)}(?:/|/\\*\\*)?$`).test(entry.trim());
}

/** The first of `names` that exists under `root`, or null. */
const firstOf = (root, names, exists) => names.find((name) => exists(path.join(root, name))) ?? null;

/** Strips `//` and `/* *\/` comments outside strings, for JSON with comments. */
export function stripComments(text) {
  return text.replace(/("(?:\\.|[^"\\])*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (match, string) => string ?? '');
}

/** The quoted strings inside the TOML array `key = [...]` of `text`. */
function tomlArray(text, key) {
  const match = new RegExp(`^\\s*${escape(key)}\\s*=\\s*\\[([\\s\\S]*?)\\]`, 'm').exec(text);
  return match ? [...match[1].matchAll(/"((?:\\.|[^"\\])*)"|'([^']*)'/g)].map((m) => m[1] ?? m[2]) : [];
}

/**
 * A Biome configuration with what its `extends` files hold merged in. Biome
 * concatenates `files.includes` base first, so a negated entry a shared preset
 * holds skips the directory as surely as one of the app's own. A relative
 * specifier is a path from the configuration's directory; anything else is a
 * package export, resolved from the configuration the way Node resolves it.
 * `//` (the monorepo root) has no file of its own here and is left out.
 */
export function biomeExtends(config, file, { read, resolve }, seen = new Set([file])) {
  const includes = [];
  const ignore = [];
  for (const specifier of [config.extends ?? []].flat()) {
    if (specifier === '//') continue;
    const base = specifier.startsWith('.') ? path.resolve(path.dirname(file), specifier) : resolve(specifier, file);
    if (seen.has(base)) continue;
    seen.add(base);
    const merged = biomeExtends(JSON.parse(stripComments(read(base))), base, { read, resolve }, seen);
    includes.push(...merged.files.includes);
    ignore.push(...merged.files.ignore);
  }
  return {
    ...config,
    files: {
      ...config.files,
      includes: [...includes, ...(config.files?.includes ?? [])],
      ignore: [...ignore, ...(config.files?.ignore ?? [])],
    },
  };
}

/** Node's resolution of `specifier` from `file`, package exports included. */
const resolveFrom = (specifier, file) => createRequire(file).resolve(specifier);

// -- the text checks: (parsed configuration, directory) -> missing | null ----

export const TEXT_CHECKS = [
  {
    tool: 'Biome',
    files: ['biome.json', 'biome.jsonc'],
    parse: (text) => JSON.parse(stripComments(text)),
    expand: biomeExtends,
    skips: (config, dir) =>
      (config.files?.includes ?? []).some((entry) => /^!{1,2}/.test(entry) && namesDirectory(entry.replace(/^!{1,2}/, ''), dir)) ||
      (config.files?.ignore ?? []).some((entry) => namesDirectory(entry, dir)),
    fix: (dir) => `add "!!${dir}" to files.includes`,
  },
  {
    tool: 'tsc',
    files: ['tsconfig.json'],
    parse: (text) => JSON.parse(stripComments(text)),
    skips: (config, dir) =>
      (config.exclude ?? []).some((entry) => namesDirectory(entry, dir)) ||
      (Array.isArray(config.include) && config.include.every((entry) => !/^[*.]/.test(entry))),
    fix: (dir) => `add "${dir}" to exclude`,
  },
  {
    tool: 'knip',
    files: ['knip.json', 'knip.jsonc', '.knip.json', '.knip.jsonc'],
    parse: (text) => JSON.parse(stripComments(text)),
    skips: (config, dir) =>
      [config.ignore ?? []].flat().some((entry) => namesDirectory(entry, dir)) ||
      [...[config.entry ?? []].flat(), ...[config.project ?? []].flat()].every((glob) => !/(^|\/)\.[^/.]/.test(glob)),
    fix: (dir) => `add "${dir}/**" to ignore, or keep every entry and project glob out of dot directories`,
  },
  {
    tool: 'typos',
    files: ['typos.toml', '_typos.toml', '.typos.toml'],
    parse: (text) => tomlArray(text, 'extend-exclude'),
    skips: (excluded, dir) => excluded.some((entry) => namesDirectory(entry, dir)),
    fix: (dir) => `add "${dir}/" to [files] extend-exclude`,
  },
  {
    tool: 'git',
    files: ['.gitignore'],
    parse: (text) => text.split('\n'),
    skips: (lines, dir) => lines.some((line) => namesDirectory(line, dir)),
    fix: (dir) => `add /${dir}/`,
  },
  {
    tool: 'Semgrep',
    files: ['.semgrepignore'],
    parse: (text) => text.split('\n'),
    expand: (lines) => [...readFileSync(PACKAGED_SEMGREPIGNORE, 'utf8').split('\n'), ...lines],
    skips: (lines, dir) => lines.some((line) => namesDirectory(line, dir)),
    fix: (dir) => `add ${dir}/`,
  },
  {
    tool: 'CodeQL',
    files: ['.github/codeql/codeql-config.yml', '.github/codeql/codeql-config.yaml'],
    parse: (text) => yamlList(text, 'paths-ignore'),
    expand: (ignored) => [...yamlList(readFileSync(PACKAGED_CODEQL_CONFIG, 'utf8'), 'paths-ignore'), ...ignored],
    skips: (ignored, dir) => ignored.some((entry) => namesDirectory(entry, dir)),
    fix: (dir) => `add "- ${dir}" to paths-ignore`,
  },
];

// -- the behaviour checks, which load the tool's own configuration ----------

const JEST_CHILD = `
const { pathToFileURL } = await import('node:url');
const loaded = await import(pathToFileURL(process.argv[1]).href);
let config = loaded.default ?? loaded;
if (typeof config === 'function') config = await config();
console.log(JSON.stringify(config));`;

const METRO_CHILD = `
const { createRequire } = await import('node:module');
const { pathToFileURL } = await import('node:url');
let config;
try {
  config = createRequire(process.argv[1])(process.argv[1]);
} catch {
  const loaded = await import(pathToFileURL(process.argv[1]).href);
  config = loaded.default ?? loaded;
}
if (typeof config === 'function') config = await config();
config = await config;
console.log(JSON.stringify([].concat(config?.resolver?.blockList ?? []).map((pattern) => [pattern.source, pattern.flags])));`;

const ESLINT_CHILD = `
const { createRequire } = await import('node:module');
const { pathToFileURL } = await import('node:url');
const [root, files] = [process.argv[1], JSON.parse(process.argv[2])];
const loaded = await import(pathToFileURL(createRequire(root + '/package.json').resolve('eslint')).href);
const eslint = new (loaded.ESLint ?? loaded.default.ESLint)({ cwd: root });
console.log(JSON.stringify(await Promise.all(files.map((file) => eslint.isPathIgnored(file)))));`;

/**
 * Runs `code` in a child node in `root` and returns what it printed, as JSON.
 * Coverage collection is off in the child: what it loads is the repository's
 * configuration, not this package.
 */
export function evaluate(code, args, root) {
  const stdout = execFileSync(process.execPath, ['--input-type=module', '--eval', code, ...args], {
    cwd: root,
    env: { ...process.env, NODE_V8_COVERAGE: '' },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return JSON.parse(stdout);
}

/** Where Jest would still walk into `dir`, one line each, for a loaded configuration. */
export function jestProblems(config, root, dir, worktrees) {
  const projects = (config.projects ?? [config]).filter((project) => typeof project === 'object');
  const matches = (patterns, rootDir, file) => patterns.some((p) => new RegExp(p.replaceAll('<rootDir>', rootDir)).test(file));
  // A root that is itself a worktree of another clone, when dir holds them.
  const roots = dir === worktrees ? [root, path.join('/repo', dir, 'feature')] : [root];
  const problems = [];
  for (const [index, project] of projects.entries()) {
    const name = project.displayName?.name ?? project.displayName ?? `project ${index + 1}`;
    const rooted = (project.testMatch ?? []).length > 0 && project.testMatch.every((glob) => /^<rootDir>\/[^*?{[./][^/*?{[]*\//.test(glob));
    for (const option of JEST_OPTIONS) {
      const patterns = project[option] ?? [];
      for (const rootDir of roots) {
        const inside = path.join(rootDir, dir, 'probe', 'src', 'a.test.ts');
        if (!(option === 'testPathIgnorePatterns' && rooted) && !matches(patterns, rootDir, inside)) {
          problems.push(`Jest (${name}) ${option} does not skip ${dir}${rootDir === root ? '' : ` from a root under ${dir}`}: add '<rootDir>/${escape(dir).replaceAll('\\', '\\\\')}/'`);
        }
        if (matches(patterns, rootDir, path.join(rootDir, 'src', 'a.test.ts'))) {
          problems.push(`Jest (${name}) ${option} hides this checkout${rootDir === root ? '' : ` when its root is under ${dir}`}: anchor the ${dir} pattern to <rootDir>`);
        }
      }
    }
  }
  return [...new Set(problems)];
}

/** Where Metro's blockList misses `dir` or blocks too much, one line each. */
export function metroProblems(blockList, root, dir) {
  const patterns = blockList.map(([source, flags]) => new RegExp(source, flags));
  const blocked = (file) => patterns.some((pattern) => pattern.test(file));
  const problems = [];
  if (!blocked(path.join(root, dir, 'probe', 'src', 'a.ts'))) problems.push(`Metro's resolver.blockList does not block ${dir}`);
  // Expo's crawler also tests the project-relative directory, to prune it.
  else if (!blocked(dir)) problems.push(`Metro's resolver.blockList does not block the relative ${dir}, which Expo's crawler asks about`);
  if (blocked(path.join(root, 'src', 'a.ts'))) problems.push(`Metro's resolver.blockList blocks this checkout: anchor the ${dir} pattern to the root`);
  if (blocked(path.join(root, `${dir}-notes`, 'a.ts'))) problems.push(`Metro's resolver.blockList blocks ${dir}-notes too: end the ${dir} pattern at a separator`);
  return problems;
}

/** The zizmor calls among `git grep` lines (`file:line:text`) that do not pass --config. */
export function zizmorProblems(lines) {
  return lines.filter((line) => !/--config[\s=]/.test(line.split(':').slice(2).join(':')));
}

/**
 * Every line of a tracked file, less markdown, that calls zizmor with an
 * option, as `file:line:text`. git grep rather than reading each file: it skips
 * binaries, and it exits 1 for "no match", which is not a failure.
 */
export function zizmorCalls(root, env = process.env) {
  try {
    return execFileSync('git', ['grep', '-n', '-I', '-E', '(^|[[:space:]"\'`(])zizmor[[:space:]]+-', '--', ':!*.md'], {
      cwd: root,
      env,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
      .split('\n')
      .filter(Boolean);
  } catch (e) {
    if (e.status === 1) return [];
    throw e;
  }
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    log = console.log,
    error = console.error,
    cwd = process.cwd(),
    read = (file) => readFileSync(file, 'utf8'),
    exists = existsSync,
    grep = zizmorCalls,
    run = evaluate,
    resolve = resolveFrom,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`ignored directories: ${e.message}`);
    return 1;
  }
  const { root, directories, worktrees } = options;
  const problems = [];
  const checked = [];
  const load = (tool, file, how) => {
    try {
      return how();
    } catch (e) {
      problems.push(`${tool} (${file}) could not be read: ${e.message.split('\n')[0]}`);
      return null;
    }
  };

  for (const check of TEXT_CHECKS) {
    const file = firstOf(root, check.files, exists);
    if (file === null) continue;
    checked.push(check.tool);
    const absolute = path.join(root, file);
    const config = load(check.tool, file, () => {
      const parsed = check.parse(read(absolute));
      return check.expand ? check.expand(parsed, absolute, { read, resolve }) : parsed;
    });
    if (config === null) continue;
    for (const dir of directories) {
      if (!check.skips(config, dir)) problems.push(`${check.tool} (${file}) does not skip ${dir}: ${check.fix(dir)}`);
    }
  }

  const jestFile = firstOf(root, ['jest.config.ts', 'jest.config.mts', 'jest.config.js', 'jest.config.mjs', 'jest.config.cjs'], exists);
  if (jestFile !== null) {
    checked.push('Jest');
    const config = load('Jest', jestFile, () => run(JEST_CHILD, [path.join(root, jestFile)], root));
    if (config !== null) for (const dir of directories) problems.push(...jestProblems(config, root, dir, worktrees));
  }

  const metroFile = firstOf(root, ['metro.config.js', 'metro.config.cjs', 'metro.config.mjs'], exists);
  if (metroFile !== null) {
    checked.push('Metro');
    const blockList = load('Metro', metroFile, () => run(METRO_CHILD, [path.join(root, metroFile)], root));
    if (blockList !== null) for (const dir of directories) problems.push(...metroProblems(blockList, root, dir));
  }

  const eslintFile = firstOf(root, ['eslint.config.js', 'eslint.config.mjs', 'eslint.config.cjs', 'eslint.config.ts'], exists);
  if (eslintFile !== null) {
    checked.push('ESLint');
    // A plain .mjs file is linted under every flat configuration, so only an
    // ignore can keep ESLint away from one.
    const probes = [path.join(root, 'probe.mjs'), ...directories.map((dir) => path.join(root, dir, 'probe', 'probe.mjs'))];
    const ignored = load('ESLint', eslintFile, () => run(ESLINT_CHILD, [root, JSON.stringify(probes)], root));
    if (ignored !== null) {
      if (ignored[0]) problems.push(`ESLint (${eslintFile}) ignores this checkout's own files`);
      directories.forEach((dir, index) => {
        if (!ignored[index + 1]) problems.push(`ESLint (${eslintFile}) does not ignore ${dir}: add '${dir}/**' to the ignores`);
      });
    }
  }

  const calls = load('zizmor', 'git grep', () => grep(root));
  if (calls !== null) {
    checked.push('zizmor');
    for (const call of zizmorProblems(calls)) problems.push(`zizmor is called without --config: ${call}`);
  }

  if (problems.length > 0) {
    for (const problem of problems) error(problem);
    error(`ignored directories: ${problems.length} problem(s)`);
    return 1;
  }
  log(`ignored directories ok (${directories.join(', ')}; ${checked.join(', ')})`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
