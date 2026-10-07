#!/usr/bin/env node
// What an Expo prebuild produces, checked against what the app's config plugins
// are supposed to put in it.
//
//   check-prebuild [--root DIR] [--keep]
//
// `ios/` and `android/` are build output here, never committed, so a plugin that
// edits an Info.plist or a Gradle file can only be tested by running the prebuild
// and reading the result. This copies the app into a temporary directory (without
// node_modules, `ios/`, `android/` and the like, which it links or leaves out),
// runs the prebuild there, and checks the generated files against the assertions
// in the `prebuild` section of app-tooling.json:
//
//   "prebuild": {
//     "scenarios": {
//       "default": {
//         "label": "OTA off",
//         "env": { "APP_VARIANT": "production", "APP_VERSION": "1.2.3" },
//         "assert": [
//           { "file": "ios/*/Info.plist", "contains": "<key>AppBuildStamp</key>", "message": "..." },
//           { "file": "ios/*/Supporting/Expo.plist", "absent": "EXUpdatesCodeSigningCertificate" },
//           { "file": "ios/*/Supporting/Expo.plist", "pattern": "<key>EXUpdatesEnabled</key>\\s*<false/>" },
//           { "exists": "ios/**/SplashScreenBackground.colorset" }
//         ]
//       }
//     }
//   }
//
// One prebuild per scenario: a plugin that behaves differently with a variable on
// (OTA) needs the build with it on and the build with it off. Every assertion of a
// scenario is checked and every failure listed, so one run says everything that
// is wrong. `--keep` leaves the temporary directory behind to look at.
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ConfigError, prebuildConfig, readSection } from '../lib/config.mjs';
import { globFiles } from '../lib/glob-files.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

const USAGE = 'usage: check-prebuild [--root DIR] [--keep]';

/** What a copy of the app leaves out: dependencies and generated projects (linked or rebuilt), other checkouts, build output. */
export const DEFAULT_EXCLUDE = ['node_modules', 'ios', 'android', '.git', '.expo', '.claude/worktrees', '.workflows', 'dist', 'coverage'];

/** Whether the repository-relative `relative` is one of `exclude` or lies under it. */
export const isExcluded = (relative, exclude) => exclude.some((entry) => relative === entry || relative.startsWith(`${entry}/`));

/** One failing assertion as a line: its own message when it has one, else what was found. */
export const describeFailure = (assertion, found) => assertion.message ?? found;

/**
 * The failures among a scenario's assertions, against the generated project in
 * `directory`: a line each, empty when everything holds.
 */
export function failures(directory, assertions, { read = (file) => readFileSync(file, 'utf8'), glob = globFiles } = {}) {
  const found = [];
  for (const assertion of assertions) {
    if (assertion.kind === 'exists') {
      if (glob(directory, assertion.value).length === 0) {
        found.push(describeFailure(assertion, `nothing matches ${assertion.value}`));
      }
      continue;
    }
    const files = glob(directory, assertion.file);
    if (files.length === 0) {
      found.push(describeFailure(assertion, `${assertion.file}: no file matches`));
      continue;
    }
    const texts = files.map((file) => read(path.join(directory, file)));
    const holds = (text) => (assertion.kind === 'pattern' ? new RegExp(assertion.value, 's').test(text) : text.includes(assertion.value));
    if (assertion.kind === 'absent') {
      if (texts.some(holds)) found.push(describeFailure(assertion, `${files.find((_, i) => holds(texts[i]))} holds ${JSON.stringify(assertion.value)}`));
    } else if (!texts.some(holds)) {
      found.push(describeFailure(assertion, `${assertion.file} ${assertion.kind === 'pattern' ? 'has no match for' : 'lacks'} ${JSON.stringify(assertion.value)}`));
    }
  }
  return found;
}

/** Copies the app into `sandbox` without what `exclude` names, and links its node_modules. */
export function copyApp(root, sandbox, exclude, { copy = cpSync, link = symlinkSync, has = existsSync } = {}) {
  copy(root, sandbox, { recursive: true, filter: (source) => !isExcluded(path.relative(root, source).split(path.sep).join('/'), exclude) });
  if (has(path.join(root, 'node_modules'))) link(path.join(root, 'node_modules'), path.join(sandbox, 'node_modules'));
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    cwd = process.cwd(),
    env = process.env,
    log = console.log,
    error = console.error,
    read = (file) => {
      try {
        return readFileSync(file, 'utf8');
      } catch {
        return null;
      }
    },
    makeSandbox = (name) => mkdtempSync(path.join(tmpdir(), `check-prebuild-${name}-`)),
    copy = copyApp,
    run = (command, args, options) => spawnSync(command, args, { stdio: ['ignore', 'inherit', 'inherit'], ...options }),
    check = failures,
    remove = (directory) => rmSync(directory, { recursive: true, force: true }),
  } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let root = cwd;
  let keep = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--keep') keep = true;
    else if (argv[i] === '--root' && argv[i + 1]) root = path.resolve(cwd, argv[++i]);
    else {
      error(USAGE);
      return 2;
    }
  }
  let config;
  try {
    config = prebuildConfig(readSection(root, 'prebuild', read));
  } catch (e) {
    if (!(e instanceof ConfigError)) throw e;
    error(`check-prebuild: ${e.message}`);
    return 2;
  }
  const exclude = [...DEFAULT_EXCLUDE, ...config.exclude];
  let bad = 0;
  for (const scenario of config.scenarios) {
    const sandbox = makeSandbox(scenario.name);
    try {
      copy(root, sandbox, exclude);
      const [program, ...args] = config.command;
      const result = run(program, args, { cwd: sandbox, env: { ...env, EXPO_NO_GIT_STATUS: '1', ...scenario.env } });
      if (result.error || result.status !== 0) {
        error(`check-prebuild (${scenario.label}): the prebuild failed${result.error ? `: ${result.error.message}` : ` with exit status ${result.status}`}`);
        bad++;
        continue;
      }
      const wrong = check(sandbox, scenario.assertions);
      if (wrong.length > 0) {
        for (const line of wrong) error(`check-prebuild (${scenario.label}): ${line}`);
        bad++;
      } else {
        log(`prebuild check passed (${scenario.label})`);
      }
    } finally {
      if (keep) log(`kept ${sandbox}`);
      else remove(sandbox);
    }
  }
  return bad === 0 ? 0 : 1;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
