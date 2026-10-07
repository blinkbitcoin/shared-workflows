#!/usr/bin/env node
// The offline test suite of every agent skill a repository ships. A skill under
// `.claude/skills/<name>/` that has tests keeps them behind one entry point,
// `tests/run.sh`, which drives the skill's commands against fakes; this runs
// each of them, in name order, and stops at the first that fails. A repository
// with no skills, or none with tests, passes: there is nothing to break.
//
//   check-skills [--root DIR]   (default: the working directory)
//
// The suites run from the repository root, the directory they were written
// against. Some drive fastlane, so the caller runs this where the release gate
// runs (`make check-release`), with the Ruby bundle installed.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

export const SKILLS_DIR = '.claude/skills';
export const SUITE = 'tests/run.sh';

/** Each skill's suite under `root`, relative to it, in name order. */
export function findSkillSuites(root) {
  const skills = path.join(root, SKILLS_DIR);
  if (!existsSync(skills)) return [];
  return readdirSync(skills, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.posix.join(SKILLS_DIR, entry.name, SUITE))
    .filter((suite) => existsSync(path.join(root, suite)))
    .sort();
}

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

const bash = (suite, root) => spawnSync('bash', [suite], { cwd: root, stdio: 'inherit' }).status ?? 1;

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), run = bash } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let root;
  try {
    ({ root } = parseArgs(argv, cwd));
  } catch (e) {
    error(`skills: ${e.message}`);
    return 1;
  }
  const suites = findSkillSuites(root);
  if (suites.length === 0) {
    log(`skills: no skill under ${SKILLS_DIR}/ has a ${SUITE}`);
    return 0;
  }
  for (const suite of suites) {
    log(`== ${suite}`);
    const status = run(suite, root);
    if (status !== 0) {
      error(`skills: ${suite} failed (exit ${status})`);
      return status;
    }
  }
  log(`skills ok (${suites.length} suite${suites.length === 1 ? '' : 's'})`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
