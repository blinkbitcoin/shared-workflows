#!/usr/bin/env node
// Point every package this family ships at the commit the workflows pin, and
// relock. Run it on a Dependabot pin bump: Dependabot moves the `uses:` pins and
// cannot move a git dependency with them, so the contract's `one-pin` row stays
// red until this runs.
//
// Usage: fix-tooling-pin [--root DIR]   (default: the working directory)
import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { isCommit, pinProblems, sharedDeps, specFor, workflowsPin } from '../lib/pin.mjs';

/** The consumer's workflow files, as `[{ name, text }]`. */
export function readCallers(root) {
  const dir = path.join(root, '.github', 'workflows');
  let names;
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  return names
    .filter((name) => name.endsWith('.yml') || name.endsWith('.yaml'))
    .sort()
    .map((name) => ({ name, text: readFileSync(path.join(dir, name), 'utf8') }));
}

function readOrNull(file) {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

/** `{ root }` from the arguments, or `{ error }`. */
export function parseArgs(argv, cwd) {
  if (argv.length === 0) return { root: cwd };
  if (argv[0] === '--root' && argv.length === 2) return { root: path.resolve(cwd, argv[1]) };
  return { error: 'usage: fix-tooling-pin [--root DIR]' };
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = [],
  { cwd = process.cwd(), log = console.log, error = console.error, exec = execFileSync } = {},
) {
  const args = parseArgs(argv, cwd);
  if (args.error) {
    error(args.error);
    return 2;
  }
  const { root } = args;
  const callers = readCallers(root);
  const { pin, problems } = workflowsPin(callers);
  if (pin === null) {
    for (const problem of problems) error(problem);
    return 1;
  }
  if (!isCommit(pin)) {
    error(`the workflows call shared-workflows at ${pin}, a tag that moves: pin a commit SHA to take packages at the same commit`);
    return 1;
  }
  const file = path.join(root, 'package.json');
  const text = readOrNull(file);
  if (text === null) {
    error(`no package.json in ${root}`);
    return 1;
  }
  const pkg = JSON.parse(text);
  const deps = sharedDeps(pkg).filter((dep) => dep.dir !== null);
  if (deps.length === 0) {
    error(`package.json takes no package from shared-workflows as github:...#<sha>&path:/packages/<name>`);
    return 1;
  }
  for (const dep of deps) pkg[dep.field][dep.name] = specFor(pin, dep.dir);
  writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
  exec('pnpm', ['install'], { cwd: root, stdio: 'inherit' });
  const left = pinProblems({ callers, pkg, lockfile: readOrNull(path.join(root, 'pnpm-lock.yaml')) });
  if (left.length > 0) {
    for (const problem of left) error(problem);
    return 1;
  }
  log(`${deps.map((dep) => dep.name).join(', ')} at the workflows pin, ${pin}`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main(process.argv.slice(2));
