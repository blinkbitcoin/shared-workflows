#!/usr/bin/env node
// Assert the tools actually on PATH are the versions the baseline pins.
//
//   check-tool-versions [tool...]
//
// With no arguments every tool in versions.json is checked. Name tools to
// check a subset - a repo that does not use `typos` should not be told its
// `typos` is missing.
//
// This asks each tool its own version rather than reading a provisioner's
// config, and that is the whole point. Reading `.mise.toml` would prove only
// that a file says 24, and would be unusable in a repo that provisions through
// Nix. Running `node --version` proves what a developer and CI will actually
// run, under any provisioner.
import { spawnSync } from 'node:child_process';
import { readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** The table, as `{ tools: { name: { version, args, match } } }`. */
export function readTable(file = path.join(HERE, '..', 'versions.json')) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

// Every pinned tool prints its version as the first dotted number in its
// output - `1.7.12`, `version: 0.11.0`, `typos-cli 1.50.1`, `v24.20.0`,
// `Bats 1.14.0`. A per-tool `pattern` overrides this when some future tool
// leads with an unrelated number.
export function extractVersion(output, pattern) {
  const match = (output ?? '').match(pattern ? new RegExp(pattern) : /\d+(?:\.\d+)+/);
  return match ? (match[1] ?? match[0]) : undefined;
}

/** Whether `found` satisfies `want` under `match` ("exact" or "major"). */
export function satisfies(found, want, match) {
  if (found === undefined) return false;
  if (match === 'major') return found.split('.')[0] === String(want).split('.')[0];
  return found === want;
}

/**
 * Checks `names` against `table`, returning one result per tool. `run` is
 * injected so the tests never depend on what is installed.
 */
export function checkTools(table, names, run) {
  return names.map((name) => {
    const spec = table.tools[name];
    if (!spec) return { name, status: 'unknown' };
    const { status, stdout, stderr } = run(name, spec.args ?? ['--version']);
    if (status === null) return { name, status: 'missing', want: spec.version };
    const found = extractVersion(`${stdout ?? ''}${stderr ?? ''}`, spec.pattern);
    const ok = satisfies(found, spec.version, spec.match);
    return { name, status: ok ? 'ok' : 'mismatch', want: spec.version, found };
  });
}

export function formatResult(result) {
  const { name, status, want, found } = result;
  if (status === 'ok') return `  ok       ${name} ${found}`;
  if (status === 'unknown') return `  unknown  ${name} is not in versions.json`;
  if (status === 'missing') return `  missing  ${name} is not on PATH (baseline pins ${want})`;
  return `  MISMATCH ${name} is ${found ?? 'unreadable'}, baseline pins ${want}`;
}

/**
 * Runs one tool the way `checkTools` wants it run: `{ status: null }` when the
 * command never started, the spawnSync result otherwise.
 */
export function runTool(name, args) {
  const result = spawnSync(name, args, { encoding: 'utf8' });
  // A command that never started has no exit code of its own.
  return result.error ? { status: null } : result;
}

/**
 * The whole program, returning its exit code. The table, the tool runner and
 * both output streams arrive through the second argument, so the tests run
 * every path of it in-process; the defaults are the real ones.
 */
export function main(
  argv,
  { table = readTable(), run = runTool, stdout = process.stdout, stderr = process.stderr } = {},
) {
  const wanted = argv.length > 0 ? argv : Object.keys(table.tools);
  const results = checkTools(table, wanted, run);
  for (const result of results) stdout.write(`${formatResult(result)}\n`);
  const bad = results.filter((r) => r.status !== 'ok');
  if (bad.length > 0) {
    const names = bad.map((r) => r.name).join(', ');
    stderr.write(`::error::tool versions disagree with the baseline: ${names}\n`);
    return 1;
  }
  stdout.write(`tool versions ok (${results.length} checked)\n`);
  return 0;
}

/**
 * Whether the module at `moduleUrl` was run as a program, given the script path
 * node was started with (`process.argv[1]`), rather than imported.
 *
 * `realpathSync`, not `path.resolve` alone: node resolves symlinks when it loads
 * a module, so `import.meta.url` is the real path while `process.argv[1]` is
 * what the caller typed. A package manager installs a `bin` entry into
 * node_modules/.bin as a link, so the advertised `pnpm exec check-tool-versions`
 * made the two differ - and this guard then said "imported": no output, exit 0,
 * a version gate that silently passed. Only `node packages/.../bin/x.mjs`, the
 * path `make tool-versions` happens to use, ever ran.
 */
export function isProgram(moduleUrl, scriptPath) {
  if (!scriptPath) return false;
  try {
    return fileURLToPath(moduleUrl) === realpathSync(path.resolve(scriptPath));
  } catch {
    return false;
  }
}

// `exitCode`, not `process.exit()`: the process ends on its own once stdout has
// drained, so the report piped to a slow reader is never cut short.
if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main(process.argv.slice(2));
