#!/usr/bin/env node
// A make target is named for what it checks or does, never after the tool that
// does it: `check-unused`, not `check-knip`. A tool's name tells a reader
// nothing until they already know the tool; it belongs in the target's `##`
// description, where `make help` shows it beside the name.
//
//   check-make-target-names [--root DIR] [--allow TARGET=REASON ...] [--require-mise]
//
// The tools are the ones the repository pins in `.mise.toml` and the unscoped
// packages in its `package.json` (either may be absent). A scoped package is
// left out: its last segment is often a plain word like `client`
// (`@apollo/client`) rather than a tool's name. A `setup-` target installs the
// tool it names, so it is spared. Any other exception is an --allow with its
// reason, and an allowance that no longer applies is itself a failure, so the
// list cannot rot.
//
// --require-mise fails when `.mise.toml` is missing or pins no tool. Without it a
// missing file reads as no tools, which is right for a repository without mise
// and wrong for one that has it: every tool-named target would then pass.
//
// The Makefile's `include` and `-include` lines are followed to the files that
// exist, so a target defined in a shared `.mk` fragment is held to the rule too.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { documentedTargets as documented, expandIncludes } from '../lib/makefile.mjs';

/** The `##`-documented targets of a Makefile, the ones `make help` lists. */
export function documentedTargets(makefile) {
  return documented(makefile).map(({ target }) => target);
}

/** The tools a `.mise.toml` pins: its [tools] keys, without a backend prefix. */
export function miseTools(toml) {
  const tools = toml.split(/^\[/m).find((section) => section.startsWith('tools]')) ?? '';
  return tools
    .split('\n')
    .slice(1)
    .map((line) => line.match(/^"?([^"=\s]+)"?\s*=/)?.[1])
    .filter(Boolean)
    .map((name) =>
      name
        .replace(/^[a-z]+:/, '')
        .split('/')
        .pop(),
    );
}

/** The unscoped package names a package.json depends on. */
export function packageNames(pkg) {
  return Object.keys({ ...pkg.dependencies, ...pkg.devDependencies }).filter((name) => !name.startsWith('@'));
}

/** `target (word)` for each target with a dash-separated word that is a tool's name. */
export function namedAfterTools(targets, tools, allowed) {
  const names = new Set(tools);
  return targets
    .filter((target) => !target.startsWith('setup-') && !allowed.has(target))
    .flatMap((target) => {
      const word = target.split('-').find((part) => names.has(part));
      return word ? [`${target} (${word})`] : [];
    });
}

/** `--root DIR`, each `--allow TARGET=REASON` and `--require-mise`, as `{ root, allowed, requireMise }`. */
export function parseArgs(argv, cwd) {
  let root = cwd;
  let requireMise = false;
  const allowed = new Map();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--require-mise') {
      requireMise = true;
      continue;
    }
    const value = argv[++i];
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else if (arg === '--allow' && /^[a-zA-Z0-9_-]+=\s*\S/.test(value ?? '')) {
      const at = value.indexOf('=');
      allowed.set(value.slice(0, at), value.slice(at + 1).trim());
    } else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --root DIR, --allow TARGET=REASON and --require-mise`);
  }
  return { root, allowed, requireMise };
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
  { log = console.log, error = console.error, cwd = process.cwd(), read = readOrNull } = {},
) {
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`make target names: ${e.message}`);
    return 1;
  }
  const { root, allowed, requireMise } = options;
  const makefile = expandIncludes(path.join(root, 'Makefile'), read, root);
  if (makefile === null) {
    error(`make target names: no Makefile in ${root}`);
    return 1;
  }
  const targets = documentedTargets(makefile);
  let pkg = {};
  const pkgText = read(path.join(root, 'package.json'));
  if (pkgText !== null) {
    try {
      pkg = JSON.parse(pkgText);
    } catch (e) {
      error(`make target names: ${path.join(root, 'package.json')} is not valid JSON: ${e.message}`);
      return 1;
    }
  }
  const mise = miseTools(read(path.join(root, '.mise.toml')) ?? '');
  if (requireMise && mise.length === 0) {
    error(`make target names: --require-mise, and ${path.join(root, '.mise.toml')} is missing or pins no tool`);
    return 1;
  }
  const tools = [...mise, ...packageNames(pkg)];
  const problems = namedAfterTools(targets, tools, allowed).map(
    (found) => `${found} is named after a tool: name it for what it checks or does, and put the tool in its ## description`,
  );
  for (const target of allowed.keys()) {
    if (!targets.includes(target)) problems.push(`--allow ${target} names no documented make target; drop it`);
    else if (namedAfterTools([target], tools, new Map()).length === 0) {
      problems.push(`--allow ${target} is no longer named after a tool; drop it`);
    }
  }
  if (problems.length > 0) {
    for (const problem of problems) error(problem);
    error(`make target names: ${problems.length} problem(s)`);
    return 1;
  }
  log(`make target names ok (${targets.length} targets, ${tools.length} tools)`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
