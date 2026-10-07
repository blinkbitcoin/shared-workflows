#!/usr/bin/env node
// Checks that this machine can build and test the app in the current
// directory, and prints the fix for each thing that is off.
//
//   doctor [--root DIR]
//
// The requirements are this package's doctor.requirements.json: the toolchain
// every app on the baseline needs, with the setup script that fixes each tool
// as its hint. A repository adds or replaces entries by name in its own
// doctor.requirements.json at its root, and drops one with `"skip": true`. An
// entry with `when` applies only when that file exists in the repository (the
// Ruby gems only where there is a Gemfile). Exits 1 while a required entry
// fails; an `optional` tool only warns.
import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

export const DEFAULTS = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'doctor.requirements.json');
const SECTIONS = ['tools', 'commands', 'env'];

export function parseVersion(output) {
  const m = /(\d+)\.(\d+)(?:\.(\d+))?/.exec(output);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3] ?? 0)];
}

export function compareVersions(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] > b[i]) return 1;
    if (a[i] < b[i]) return -1;
  }
  return 0;
}

/** A versioned tool: found, and at least its minimum. `run` is injectable. */
export function checkTool(tool, run = execSync) {
  let output;
  try {
    output = run(tool.command, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) {
    output = error.stdout ?? '';
    if (!output) return { ok: false, reason: 'not found' };
  }
  const found = parseVersion(output);
  if (!found) return { ok: false, reason: `no version in its output: ${output.trim()}` };
  const minimum = parseVersion(tool.minimum);
  if (compareVersions(found, minimum) < 0) {
    return { ok: false, reason: `found ${found.join('.')}, need >= ${tool.minimum}` };
  }
  return { ok: true, version: found.join('.') };
}

/** A pass/fail probe: no version to parse, the exit status is the answer. */
export function checkCommand(entry, run = execSync) {
  try {
    run(entry.command, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { ok: true };
  } catch (error) {
    // Whichever stream carried the message: `bundle check` writes its
    // "Could not find ..." to stderr and leaves stdout empty.
    const detail = [error.stdout, error.stderr].map((stream) => String(stream ?? '').trim()).find(Boolean);
    return { ok: false, reason: detail?.split('\n')[0] || 'command failed' };
  }
}

/**
 * The package's requirements with a repository's on top: an entry of the same
 * name replaces the package's, a new one is added, and `"skip": true` drops it.
 */
export function mergeRequirements(base, local = {}) {
  const merged = {};
  for (const section of SECTIONS) {
    const byName = new Map((base[section] ?? []).map((entry) => [entry.name, entry]));
    for (const entry of local[section] ?? []) byName.set(entry.name, entry);
    merged[section] = [...byName.values()].filter((entry) => !entry.skip);
  }
  return merged;
}

/** The requirements for the repository at `root`. A malformed file throws, naming it. */
export function readRequirements(root, { defaults = DEFAULTS } = {}) {
  const read = (file) => {
    try {
      return JSON.parse(readFileSync(file, 'utf8'));
    } catch (error) {
      throw new Error(`${file}: ${error.message}`);
    }
  };
  const local = path.join(root, 'doctor.requirements.json');
  return mergeRequirements(read(defaults), existsSync(local) ? read(local) : {});
}

/**
 * The doctor itself; returns the exit code. Everything it touches is
 * injectable, so a test decides what is installed, what is set and which
 * files the repository has.
 */
export function check(
  req,
  { root = '.', platform = process.platform, env = process.env, run = execSync, write, exists = existsSync },
) {
  const applies = (entry) =>
    (!entry.platform || entry.platform === platform) && (!entry.when || exists(path.join(root, entry.when)));
  let failures = 0;
  for (const tool of req.tools.filter(applies)) {
    const result = checkTool(tool, run);
    if (result.ok) {
      write(`ok    ${tool.name} ${result.version}\n`);
    } else if (tool.optional) {
      write(`warn  ${tool.name}: ${result.reason}. Fix: ${tool.hint}\n`);
    } else {
      failures++;
      write(`FAIL  ${tool.name}: ${result.reason}. Fix: ${tool.hint}\n`);
    }
  }
  for (const entry of req.commands.filter(applies)) {
    const result = checkCommand(entry, run);
    if (result.ok) {
      write(`ok    ${entry.name}\n`);
    } else {
      failures++;
      write(`FAIL  ${entry.name}: ${result.reason}. Fix: ${entry.hint}\n`);
    }
  }
  for (const v of req.env.filter(applies)) {
    if (env[v.name]) {
      write(`ok    $${v.name}=${env[v.name]}\n`);
    } else {
      failures++;
      write(`FAIL  $${v.name} is not set. Fix: ${v.hint}\n`);
    }
  }
  if (failures > 0) {
    write(`\n${failures} problem(s). Fix them and run the doctor again.\n`);
    return 1;
  }
  write('\nAll good.\n');
  return 0;
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { cwd = process.cwd(), write = (text) => process.stdout.write(text), error = console.error, ...io } = {},
) {
  if (answerHelp(argv, import.meta.url, (text) => write(`${text}\n`))) return 0;
  let root = cwd;
  if (argv.length === 2 && argv[0] === '--root') root = path.resolve(cwd, argv[1]);
  else if (argv.length > 0) {
    error('usage: doctor [--root DIR]');
    return 2;
  }
  let req;
  try {
    req = readRequirements(root, io);
  } catch (e) {
    error(`doctor: ${e.message}`);
    return 2;
  }
  return check(req, { root, write, ...io });
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
