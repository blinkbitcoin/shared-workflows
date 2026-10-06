#!/usr/bin/env node
// The CodeQL configuration a repository is scanned with, written to a file:
// this package's defaults with the repository's own configuration merged over
// them (lib/codeql-config.mjs). check-code-scanning.yml runs it before the
// analysis and hands the result to codeql-action/init, so CI reads the same
// text `check-code-scanning` does on a laptop.
//
//   resolve-code-scanning-config --out FILE [--root DIR] [--config FILE]
//
// --config defaults to `.github/codeql/codeql-config.yml` under --root and need
// not exist. --out is where the merged file goes, relative to --root.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isProgram } from '../lib/is-program.mjs';
import { mergeConfig } from '../lib/codeql-config.mjs';
import { answerHelp } from '../lib/usage.mjs';

const DEFAULTS = fileURLToPath(new URL('../codeql-config.yml', import.meta.url));
const USAGE = 'pass --out FILE, and optionally --root DIR and --config FILE';

/** The arguments, as `{ root, config, out }`. */
export function parseArgs(argv, cwd) {
  const options = { root: cwd, config: '.github/codeql/codeql-config.yml', out: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--root' && value) options.root = path.resolve(cwd, value);
    else if (arg === '--config' && value) options.config = value;
    else if (arg === '--out' && value) options.out = value;
    else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: ${USAGE}`);
  }
  if (options.out === null) throw new Error(`no --out: ${USAGE}`);
  return options;
}

/** Command-line entry; returns the exit code. */
export function main(argv = process.argv.slice(2), { log = console.log, error = console.error, cwd = process.cwd() } = {}) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`resolve-code-scanning-config: ${e.message}`);
    return 1;
  }
  const { root, config, out } = options;
  let own = null;
  try {
    own = readFileSync(path.join(root, config), 'utf8');
  } catch (e) {
    if (e.code !== 'ENOENT') {
      error(`::error::${config} could not be read: ${e.message}`);
      return 1;
    }
  }
  let merged;
  try {
    merged = mergeConfig(readFileSync(DEFAULTS, 'utf8'), own, config);
  } catch (e) {
    error(`::error::${e.message}`);
    return 1;
  }
  const target = path.join(root, out);
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, merged);
  log(`resolved ${own === null ? 'the family defaults (no' : 'the family defaults with'} ${config}${own === null ? ' in this repository)' : ''} into ${out}`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
