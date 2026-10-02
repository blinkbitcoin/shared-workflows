#!/usr/bin/env node
// Everything about a repository's release tooling that can be checked offline:
// the Ruby it ships parses, fastlane can list its lanes, the lanes' own unit
// tests pass, and every agent skill's tests pass.
//
//   check-release [--fastlane-directory DIR]
//
// In order, stopping at the first that fails:
//   1. `bundle check`: the gems are installed (otherwise: run install-gems)
//   2. `ruby -c` over DIR/Fastfile, DIR/lanes/*.rb and DIR/test/*.rb
//   3. `bundle exec fastlane lanes`, without the environment assertions a
//      real lane makes (FASTLANE_SKIP_ENV_ASSERT=1)
//   4. DIR/test/lanes_test.rb under `bundle exec ruby`, when the file exists
//   5. check-skills
// DIR defaults to `fastlane`.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { main as checkSkills } from './check-skills.mjs';

/** The arguments, as `{ directory }`. */
export function parseArgs(argv) {
  let directory = 'fastlane';
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--fastlane-directory' && value) directory = value.replace(/\/+$/, '');
    else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --fastlane-directory DIR`);
  }
  return { directory };
}

/** The Ruby files under `directory` to syntax-check, relative to `root`, in order. */
export function rubyFiles(root, directory) {
  const rb = (sub) => {
    const dir = path.join(root, directory, sub);
    return existsSync(dir)
      ? readdirSync(dir)
          .filter((name) => name.endsWith('.rb'))
          .sort()
          .map((name) => path.posix.join(directory, sub, name))
      : [];
  };
  return [path.posix.join(directory, 'Fastfile'), ...rb('lanes'), ...rb('test')];
}

const spawn = (command, args, env) => spawnSync(command, args, { stdio: 'inherit', env: { ...process.env, ...env } }).status ?? 1;

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), run = spawn, skills = checkSkills, exists = existsSync } = {},
) {
  let directory;
  try {
    ({ directory } = parseArgs(argv));
  } catch (e) {
    error(`check-release: ${e.message}`);
    return 1;
  }
  const step = (label, command, args, env = {}) => {
    log(`== ${label}`);
    const status = run(command, args, env);
    if (status !== 0) error(`check-release: ${label} failed (exit ${status})`);
    return status;
  };

  log('== bundle check');
  if (run('bundle', ['check'], {}) !== 0) {
    error('check-release: the gems are not installed - run: install-gems (see docs/release-runbook.md)');
    return 1;
  }
  for (const file of rubyFiles(cwd, directory)) {
    const status = step(`ruby -c ${file}`, 'ruby', ['-c', file]);
    if (status !== 0) return status;
  }
  let status = step('fastlane lanes', 'bundle', ['exec', 'fastlane', 'lanes'], { FASTLANE_SKIP_ENV_ASSERT: '1' });
  if (status !== 0) return status;
  const lanesTest = path.posix.join(directory, 'test', 'lanes_test.rb');
  if (exists(path.join(cwd, lanesTest))) {
    status = step(lanesTest, 'bundle', ['exec', 'ruby', `-I${directory}/test`, lanesTest]);
    if (status !== 0) return status;
  }
  log('== check-skills');
  status = skills([], { cwd });
  if (status !== 0) return status;
  log('release checks ok');
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
