#!/usr/bin/env node
// Every source file has a test file of its own, beside it.
//
//   check-test-siblings [--source GLOB=SUFFIX[,SUFFIX...] ...] [--exclude GLOB ...]
//                       [--mirror FROM=TO ...] [--root DIR]
//
// The rules usually live in the repository's `app-tooling.json`, so the make
// recipe is the bare call:
//
//   "testSiblings": {
//     "sources": { "scripts/**/*.{mjs,sh}": [".test.mjs"], "src/**/*.{ts,tsx}": [".test.ts", ".test.tsx"] },
//     "exclude": ["src/graphql/generated/**", "**/*.d.ts"],
//     "mirror": { "src/app/": "src/__tests__/app/" }
//   }
//
// A flag overrides its field of the file: any --source replaces `sources`, any
// --exclude replaces `exclude`, any --mirror replaces `mirror`. A file that is
// there and wrong exits 2 with the reason.
//
// Global coverage can be 100% while a module is reached only through a
// caller's test, and then nothing fails the day that caller stops calling it.
// This holds the half a tool can see: the sibling exists. Each file's own
// coverage is then checked by running its test alone.
//
// --source says which files are sources and what their test is called: the
// file's name without its last extension, plus one of the suffixes, in the same
// directory. `scripts/**/*.{mjs,sh}=.test.mjs` gives `scripts/a.sh` the test
// `scripts/a.test.mjs`; `src/**/*.{ts,tsx}=.test.ts,.test.tsx` lets a `.ts`
// module be tested by rendering it in JSX. The first --source a file matches
// decides its suffixes. A file named `*.test.*` is a test, never a source.
//
// --exclude takes a whole class of files out of scope - generated code, test
// support, declaration files - and must say so with a glob or a directory
// (`src/graphql/generated/**`, `**/*.d.ts`). An --exclude naming one file is an
// allowlist entry, and so is --allow: this check has neither. A file that needs
// a device, a simulator or the network is tested against fakes of them. An
// --exclude that matches no file is reported, so the list cannot rot.
//
// --mirror FROM=TO is for a directory whose every file is loaded as something
// else - expo-router reads each file under `src/app/` as a route, so a test
// beside a route would be registered as one. A file under FROM is tested from
// the same path under TO (`src/app/a/[id].tsx` -> `src/__tests__/app/a/[id].test.tsx`);
// a test under FROM fails, and so does a test under TO that mirrors no file.
//
// The files are the repository's tracked ones plus untracked files git does
// not ignore, so a new module fails before it is committed.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { ConfigError, CONFIG_FILE, readSection, stringList, stringMap } from '../lib/config.mjs';
import { isProgram } from '../lib/is-program.mjs';

const TEST = /\.test\.[^/]+$/;

/** A glob as a regular expression over a whole relative path: `**`, `*`, `?` and `{a,b}`. */
export function globToRegExp(glob) {
  let source = '';
  for (let i = 0; i < glob.length; i++) {
    const char = glob[i];
    if (glob.startsWith('**/', i)) {
      source += '(?:.*/)?';
      i += 2;
    } else if (glob.startsWith('**', i)) {
      source += '.*';
      i += 1;
    } else if (char === '*') source += '[^/]*';
    else if (char === '?') source += '[^/]';
    else if (char === '{') source += '(?:';
    else if (char === '}') source += ')';
    else if (char === ',' && glob.lastIndexOf('{', i) > glob.lastIndexOf('}', i)) source += '|';
    else source += char.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${source}$`);
}

/** Whether `glob` could stand for more than one file: a wildcard, or a directory. */
const isClass = (glob) => /[*?{]/.test(glob) || glob.endsWith('/');

/** An exclude that names one file, refused: that is an allowlist entry, which this check does not have. */
function refuseSingleFile(glob, label) {
  if (!isClass(glob)) {
    throw new Error(`${label} ${glob} names one file, which is an allowlist entry: give it a test, or exclude the class of files it belongs to with a glob`);
  }
}

/** Whether the relative path `file` falls under the --exclude `glob`. */
function excludedBy(glob, file) {
  if (glob.endsWith('/')) return file.startsWith(glob);
  return globToRegExp(glob).test(file);
}

/**
 * The arguments, as `{ root, sources: [{ glob, match, suffixes }], excludes,
 * mirrors: [{ from, to }] }`. A list no flag filled is empty, and the
 * configuration file then decides it.
 */
export function parseArgs(argv, cwd) {
  let root = cwd;
  const sources = [];
  const excludes = [];
  const mirrors = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--allow') {
      throw new Error('there is no --allow: a file with no test gets one, against fakes of whatever it needs');
    }
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else if (arg === '--source' && /^[^=]+=\.[^,=]+(?:,\.[^,=]+)*$/.test(value ?? '')) {
      const [glob, suffixes] = value.split('=');
      sources.push({ glob, match: globToRegExp(glob), suffixes: suffixes.split(',') });
    } else if (arg === '--exclude' && value) {
      refuseSingleFile(value, '--exclude');
      excludes.push(value);
    } else if (arg === '--mirror' && /^[^=]+\/=[^=]+\/$/.test(value ?? '')) {
      const [from, to] = value.split('=');
      mirrors.push({ from, to });
    } else {
      throw new Error(
        `unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --source GLOB=SUFFIX[,SUFFIX], --exclude GLOB, --mirror FROM/=TO/ and --root DIR`,
      );
    }
  }
  return { root, sources, excludes, mirrors };
}

/**
 * The rules of a `testSiblings` section, in the shape parseArgs returns, or a
 * ConfigError naming what is wrong. The same rules hold as for the flags: a
 * suffix starts with a dot, a mirror is two directories, and an exclude naming
 * one file is refused.
 */
export function configRules(section) {
  const fail = (reason) => {
    throw new ConfigError(`${CONFIG_FILE}: ${reason}`);
  };
  const sources = [];
  if (section.sources !== undefined) {
    const map = section.sources;
    if (map === null || typeof map !== 'object' || Array.isArray(map)) fail('"testSiblings.sources" must be an object of glob to test suffixes');
    for (const [glob, suffixes] of Object.entries(map)) {
      stringList(suffixes, `testSiblings.sources.${glob}`);
      if (suffixes.length === 0 || !suffixes.every((suffix) => /^\.[^,=]+$/.test(suffix))) {
        fail(`"testSiblings.sources.${glob}" must list test suffixes that start with a dot, such as ".test.mjs"`);
      }
      sources.push({ glob, match: globToRegExp(glob), suffixes });
    }
  }
  const excludes = section.exclude === undefined ? [] : stringList(section.exclude, 'testSiblings.exclude');
  for (const glob of excludes) {
    try {
      refuseSingleFile(glob, '"testSiblings.exclude" entry');
    } catch (e) {
      fail(e.message);
    }
  }
  const mirrors = Object.entries(section.mirror === undefined ? {} : stringMap(section.mirror, 'testSiblings.mirror')).map(([from, to]) => {
    if (!from.endsWith('/') || !to.endsWith('/')) fail(`"testSiblings.mirror" maps a directory to a directory, each ending in a slash: "${from}": "${to}"`);
    return { from, to };
  });
  return { sources, excludes, mirrors };
}

/** Each field from the flags when any flag set it, and from the configuration file otherwise. */
export function resolveRules(flags, fromFile) {
  const pick = (key) => (flags[key].length > 0 || fromFile === null ? flags[key] : fromFile[key]);
  return { root: flags.root, sources: pick('sources'), excludes: pick('excludes'), mirrors: pick('mirrors') };
}

/** The --source rule a file is a source under, or null when it is out of scope. */
export function sourceRule(file, { sources, excludes }) {
  if (TEST.test(file)) return null;
  if (excludes.some((glob) => excludedBy(glob, file))) return null;
  return sources.find(({ match }) => match.test(file)) ?? null;
}

/** The paths a source file's own test may take. */
export function siblingsOf(file, rule, mirrors) {
  const mirror = mirrors.find(({ from }) => file.startsWith(from));
  const tested = mirror ? mirror.to + file.slice(mirror.from.length) : file;
  const { dir, name } = path.posix.parse(tested);
  return rule.suffixes.map((suffix) => path.posix.join(dir, `${name}${suffix}`));
}

/** Every problem in `files` under `options`, one line each; empty when the tree holds the rule. */
export function problems(files, options) {
  const present = new Set(files);
  const found = [];
  let sources = 0;
  for (const file of files) {
    const rule = sourceRule(file, options);
    if (rule === null) continue;
    sources++;
    const siblings = siblingsOf(file, rule, options.mirrors);
    if (!siblings.some((sibling) => present.has(sibling))) {
      found.push(`${file} has no test of its own: add ${siblings.join(' or ')}`);
    }
  }
  for (const { from, to } of options.mirrors) {
    for (const file of files.filter((f) => f.startsWith(from) && TEST.test(f))) {
      found.push(`${file} is a test under ${from}, where every file is loaded as something else: move it under ${to}`);
    }
    const stems = new Set(files.filter((f) => f.startsWith(from)).map((f) => f.slice(from.length).replace(/\.[^./]+$/, '')));
    for (const file of files.filter((f) => f.startsWith(to) && TEST.test(f))) {
      if (!stems.has(file.slice(to.length).replace(TEST, ''))) {
        found.push(`${file} mirrors no file under ${from}: rename or remove it to match`);
      }
    }
  }
  for (const glob of options.excludes) {
    if (!files.some((file) => excludedBy(glob, file))) found.push(`exclude ${glob} matches no file; drop it`);
  }
  return { sources, found };
}

const readOrNull = (file) => {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
};

const gitFiles = (root) =>
  execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  })
    .split('\0')
    .filter(Boolean);

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), listFiles = gitFiles, read = readOrNull } = {},
) {
  let flags;
  try {
    flags = parseArgs(argv, cwd);
  } catch (e) {
    error(`test siblings: ${e.message}`);
    return 1;
  }
  let options;
  try {
    const section = readSection(flags.root, 'testSiblings', read);
    options = resolveRules(flags, section === null ? null : configRules(section));
  } catch (e) {
    error(`test siblings: ${e.message}`);
    return 2;
  }
  if (options.sources.length === 0) {
    error(`test siblings: name the source files with --source GLOB=SUFFIX, or with "testSiblings.sources" in ${CONFIG_FILE}`);
    return 1;
  }
  let files;
  try {
    files = [...new Set(listFiles(options.root))].sort();
  } catch (e) {
    error(`test siblings: could not list the files of ${options.root}: ${e.message}`);
    return 1;
  }
  const { sources, found } = problems(files, options);
  if (found.length > 0) {
    for (const problem of found) error(problem);
    error(`test siblings: ${found.length} problem(s)`);
    return 1;
  }
  log(`test siblings ok (${sources} source files)`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
