#!/usr/bin/env node
// Runs the app suites (suites/index.mjs) against an app: shared tests that
// read the app's own files and run this family's code against them, where
// check-contract only asks whether those files are there. Each suite is a
// node:test file; this decides which apply, says why each other one does not,
// and runs the rest in one `node --test` with APP_ROOT set to the app.
//
//   test-app [--root DIR] [--suite NAME ...] [--list]
//
// The app is found the way check-contract finds it: the repository, then the
// working-directory its callers pass, and its native stack by the same rule.
// app-tooling.json's appSuites.skip turns a suite off, with a reason that is
// printed on every run; nothing is skipped silently.
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ConfigError, CONFIG_FILE, readSection, stringMap } from '../lib/config.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { SUITES } from '../suites/index.mjs';
import { defaultIo, readConsumer } from './check-contract.mjs';
import { answerHelp } from '../lib/usage.mjs';

export const SUITES_DIR = fileURLToPath(new URL('../suites/', import.meta.url));

const USAGE = 'pass --root DIR, --suite NAME (repeatable) and --list';

export function parseArgs(argv, cwd) {
  let root = cwd;
  const only = [];
  let list = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--list') {
      list = true;
      continue;
    }
    const value = argv[++i];
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else if (arg === '--suite' && value) only.push(value);
    else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: ${USAGE}`);
  }
  return { root, only, list };
}

/**
 * Each suite, in name order, with whether it runs and, when it does not, why.
 * `only` narrows the list to the suites it names; `skip` maps a suite to the
 * reason app-tooling.json gives for turning it off.
 */
export function plan({ suites, stack, exists, skip = {}, only = [] }) {
  const names = Object.keys(suites).sort();
  const unknown = only.filter((name) => !names.includes(name));
  if (unknown.length > 0) throw new Error(`no suite named ${unknown.join(', ')}; the suites are ${names.join(', ')}`);
  const unknownSkips = Object.keys(skip).filter((name) => !names.includes(name));
  if (unknownSkips.length > 0) {
    throw new ConfigError(`${CONFIG_FILE}: appSuites.skip names ${unknownSkips.join(', ')}, which is not a suite; the suites are ${names.join(', ')}`);
  }
  return names
    .filter((name) => only.length === 0 || only.includes(name))
    .map((name) => {
      const suite = suites[name];
      if (skip[name]) return { name, run: false, reason: `turned off in ${CONFIG_FILE}: ${skip[name]}` };
      if (!suite.stacks.includes(stack)) return { name, run: false, reason: `a ${stack} app (it is for ${suite.stacks.join(', ')})` };
      const missing = suite.needs.find((file) => !exists(file));
      if (missing) return { name, run: false, reason: `no ${missing}` };
      return { name, run: true, file: path.join(SUITES_DIR, suite.file) };
    });
}

/**
 * `node --test` over the suite files, from the app root, with APP_ROOT set,
 * and the spec reporter whatever the terminal, so a log reads the same in CI
 * as on a laptop. NODE_TEST_CONTEXT is dropped: this may itself be running under node --test,
 * and a child that inherits it reports to that runner instead of printing.
 */
export function runSuites(files, appRoot, spawn = spawnSync) {
  const { NODE_TEST_CONTEXT: _parent, ...env } = process.env;
  const result = spawn(process.execPath, ['--test', '--test-reporter=spec', ...files], {
    cwd: appRoot,
    env: { ...env, APP_ROOT: appRoot },
    stdio: 'inherit',
  });
  return result.status ?? 1;
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), io = defaultIo, suites = SUITES, run = runSuites } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`app suites: ${e.message}`);
    return 1;
  }
  let consumer;
  let steps;
  try {
    const section = readSection(options.root, 'appSuites', io.read);
    const skip = stringMap(section?.skip ?? {}, 'appSuites.skip');
    consumer = readConsumer(options.root, io);
    steps = plan({
      suites,
      stack: consumer.stack.stack,
      exists: (file) => io.exists(path.join(consumer.root, file)),
      skip,
      only: options.only,
    });
  } catch (e) {
    error(`app suites: ${e.message}`);
    return e instanceof ConfigError ? 2 : 1;
  }
  for (const step of steps) log(step.run ? `run ${step.name}` : `skip ${step.name}: ${step.reason}`);
  if (options.list) return 0;
  const files = steps.filter((step) => step.run).map((step) => step.file);
  if (files.length === 0) {
    log('app suites: none applies to this app');
    return 0;
  }
  return run(files, consumer.root);
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
