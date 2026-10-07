#!/usr/bin/env node
// `make help`: every `##`-documented target of the Makefile, sorted, with its
// description, as one line each.
//
//   help [--root DIR]
//
// The one-liner every Makefile used to carry - `grep ... $(MAKEFILE_LIST) |
// sort | awk ...` - is logic in a recipe that no test reaches, and it only sees
// the files make has already read. This follows the Makefile's `include` and
// `-include` lines to the fragments that exist, so a target a shared `.mk`
// fragment defines is listed too. A target documented twice is listed once,
// with the description make would use: the last one read.
//
// The target names are coloured when the output is a terminal and NO_COLOR is
// unset, and plain otherwise, so the list can be piped or read by a test.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { documentedTargets, expandIncludes } from '../lib/makefile.mjs';
import { answerHelp } from '../lib/usage.mjs';

/** The help lines for a Makefile's text: sorted, one per target, padded to the longest name. */
export function helpLines(text, { colour = false } = {}) {
  const described = new Map();
  for (const { target, description } of documentedTargets(text)) described.set(target, description);
  const width = Math.max(0, ...[...described.keys()].map((target) => target.length));
  return [...described.keys()].sort().map((target) => {
    const name = target.padEnd(width);
    return `${colour ? `\u001b[36m${name}\u001b[0m` : name}  ${described.get(target)}`;
  });
}

/** `--root DIR`, as `{ root }`. */
export function parseArgs(argv, cwd) {
  let root = cwd;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --root DIR`);
  }
  return { root };
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
    read = readOrNull,
    env = process.env,
    isTTY = process.stdout.isTTY === true,
  } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`make help: ${e.message}`);
    return 1;
  }
  const { root } = options;
  const text = expandIncludes(path.join(root, 'Makefile'), read, root);
  if (text === null) {
    error(`make help: no Makefile in ${root}`);
    return 1;
  }
  const lines = helpLines(text, { colour: isTTY && !env.NO_COLOR });
  if (lines.length === 0) {
    error(`make help: no target in ${path.join(root, 'Makefile')} has a ## description`);
    return 1;
  }
  for (const line of lines) log(line);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
