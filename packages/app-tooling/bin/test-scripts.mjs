#!/usr/bin/env node
// The tests of an app's own Node scripts, held to 100% coverage.
//
//   test-scripts [--root DIR]
//
// Three things in order, each a gate:
//
//   1. check-test-siblings: every script has its own test file next to it.
//   2. `node --test` over the test files, with coverage at 100% for lines,
//      branches and functions over the script modules.
//   3. Every script module is in the coverage report.
//
// The third is the one nothing else holds. Node's coverage only measures modules
// some test loaded: a module no test imports is missing from the report rather
// than reported at 0%, so an untested new script would pass the 100% gate by not
// being in it. Reading the report (lcov) against the modules on disk closes that
// without every app carrying a test that imports each script.
//
// Which files are scripts and which are tests are the `sources` and `tests` path
// patterns of the `testScripts` section of app-tooling.json (default
// `scripts/**/*.mjs` and `scripts/**/*.test.mjs`); a source that is also a test
// file is not a module. A module's command-line entry has to be guarded (an
// `import.meta.main` check, or isProgram) so importing it runs nothing.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ConfigError, readSection, testScriptsConfig } from '../lib/config.mjs';
import { globFiles } from '../lib/glob-files.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { main as siblings } from './check-test-siblings.mjs';

const USAGE = 'usage: test-scripts [--root DIR]';

/** The script modules: what `sources` names, less the test files. */
export function scriptModules(root, config, glob = globFiles) {
  const tests = new Set(config.tests.flatMap((pattern) => glob(root, pattern)));
  return [...new Set(config.sources.flatMap((pattern) => glob(root, pattern)))].filter((file) => !tests.has(file)).sort();
}

/** The repository-relative paths an lcov report covers, one `SF:` line each. */
export function coveredFiles(lcov, root) {
  return new Set(
    lcov
      .split('\n')
      .filter((line) => line.startsWith('SF:'))
      // Absolute from a plain run, relative to the working directory under an outer test runner.
      .map((line) => path.relative(root, path.resolve(root, line.slice(3).trim())).split(path.sep).join('/')),
  );
}

/** The `node --test` arguments: the gates, the coverage over the sources, both reporters, the tests. */
export function nodeArguments(config, lcovFile) {
  return [
    '--test',
    '--experimental-test-coverage',
    '--test-coverage-lines=100',
    '--test-coverage-branches=100',
    '--test-coverage-functions=100',
    ...config.sources.map((pattern) => `--test-coverage-include=${pattern}`),
    '--test-reporter=spec',
    '--test-reporter-destination=stdout',
    '--test-reporter=lcov',
    `--test-reporter-destination=${lcovFile}`,
    ...config.tests,
  ];
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    cwd = process.cwd(),
    log = console.log,
    error = console.error,
    read = (file) => {
      try {
        return readFileSync(file, 'utf8');
      } catch {
        return null;
      }
    },
    // NODE_TEST_CONTEXT marks a process as running inside node:test, and a `node --test` that
    // finds it treats itself as nested and skips every file; NODE_V8_COVERAGE is an outer run's
    // own coverage, which would take the app's scripts' coverage for its own. Neither goes on.
    run = (command, args, options) => {
      const { NODE_TEST_CONTEXT: _nested, NODE_V8_COVERAGE: _outer, ...env } = process.env;
      return spawnSync(command, args, { stdio: 'inherit', env, ...options });
    },
    checkSiblings = siblings,
    makeTemp = () => mkdtempSync(path.join(tmpdir(), 'test-scripts-')),
    remove = (directory) => rmSync(directory, { recursive: true, force: true }),
    glob = globFiles,
    // Node reports coverage by real path, and a temporary directory is often a link (/var is
    // /private/var on macOS): the root has to be the real one for the report to be read against it.
    realpath = (directory) => {
      try {
        return realpathSync(directory);
      } catch {
        return directory;
      }
    },
  } = {},
) {
  let root = cwd;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root' && argv[i + 1]) root = path.resolve(cwd, argv[++i]);
    else {
      error(USAGE);
      return 2;
    }
  }
  root = realpath(root);
  let config;
  try {
    config = testScriptsConfig(readSection(root, 'testScripts', read));
  } catch (e) {
    if (!(e instanceof ConfigError)) throw e;
    error(`test-scripts: ${e.message}`);
    return 2;
  }
  const modules = scriptModules(root, config, glob);
  if (modules.length === 0) {
    error(`test-scripts: no script module matches ${config.sources.join(', ')}; name them in "testScripts.sources" of app-tooling.json`);
    return 2;
  }

  const siblingsCode = checkSiblings(['--root', root]);
  if (siblingsCode !== 0) return siblingsCode;

  const temp = makeTemp();
  try {
    const lcovFile = path.join(temp, 'lcov.info');
    const result = run(process.execPath, nodeArguments(config, lcovFile), { cwd: root });
    if (result.error) {
      error(`test-scripts: could not run node: ${result.error.message}`);
      return 1;
    }
    if (result.status !== 0) return result.status ?? 1;
    const covered = coveredFiles(read(lcovFile) ?? '', root);
    const missing = modules.filter((file) => !covered.has(file));
    if (missing.length > 0) {
      for (const file of missing) error(`${file}: no test loaded it, so the coverage report does not contain it`);
      error(`test-scripts: ${missing.length} script module(s) are not covered at all. A module's own test file has to import it, and its command-line entry has to be guarded so importing it runs nothing`);
      return 1;
    }
    log(`script tests ok (${modules.length} modules at 100%)`);
    return 0;
  } finally {
    remove(temp);
  }
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
