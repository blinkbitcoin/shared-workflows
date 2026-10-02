#!/usr/bin/env node
// Install the repository's Ruby gems (fastlane and its plugins) under
// vendor/bundle, so `bundle exec` finds them without touching the system Ruby.
//
//   install-gems
//
// NO_BUNDLE=1 skips it, for a machine or a job that only runs the JavaScript
// checks; `check-release` says to install them when it needs them. It runs after
// `pnpm install`, which is what puts this program in node_modules.
import { spawnSync } from 'node:child_process';
import { isProgram } from '../lib/is-program.mjs';

const bundle = (args) => spawnSync('bundle', args, { stdio: 'inherit' }).status ?? 1;

/** Command-line entry; returns the exit code. */
export function main(argv = process.argv.slice(2), { env = process.env, log = console.log, error = console.error, run = bundle } = {}) {
  if (argv.length > 0) {
    error(`install-gems: unexpected ${argv.join(' ')}: it takes no arguments`);
    return 1;
  }
  if (env.NO_BUNDLE === '1') {
    log('NO_BUNDLE=1: skipping bundle install (check-release will need it)');
    return 0;
  }
  for (const args of [['config', 'set', '--local', 'path', 'vendor/bundle'], ['install']]) {
    const status = run(args);
    if (status !== 0) {
      error(`install-gems: bundle ${args[0]} failed (exit ${status})`);
      return status;
    }
  }
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
