#!/usr/bin/env node
// Turn the resolved security settings into the step outputs check-security.yml
// gates its jobs on, one `name=value` line each, for scripts/security/settings.sh.
// The settings come from the resolver (packages/app-tooling/lib/security-settings.mjs,
// `--json`); the shell script runs it, hands its answer over as the one argument,
// and publishes each line this prints.
//
//   settings.mjs SETTINGS_JSON
//
// Prints enabled, severity and fail-on, then one line per job, in the
// resolver's order. Anything that is not the settings object fails rather than
// printing a partial answer: a missing line would read as "off" to an `if:`.
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const USAGE = 'usage: settings.mjs SETTINGS_JSON';

/** The `[name, value]` outputs for `settings`, in the order they are published. */
export function outputRows(settings) {
  const rows = [
    ['enabled', settings.enabled],
    ['severity', settings.severity],
    ['fail-on', settings.failOn.join(',')],
  ];
  for (const [name, on] of Object.entries(settings.jobs)) rows.push([name, on]);
  return rows;
}

/** The rows as the lines settings.sh reads, each `name=value` and a newline. */
export function formatRows(rows) {
  return rows.map(([name, value]) => `${name}=${value}\n`).join('');
}

/**
 * The whole program, returning its exit code. Both output streams arrive
 * through the second argument, so the tests run every path of it in-process;
 * the defaults are the real ones.
 */
export function main(argv, { stdout = process.stdout, stderr = process.stderr } = {}) {
  if (argv.length !== 1) {
    stderr.write(`::error::${USAGE}\n`);
    return 2;
  }
  let text;
  try {
    text = formatRows(outputRows(JSON.parse(argv[0])));
  } catch (error) {
    // Not an annotation of its own: settings.sh fails the step with one that
    // names the resolver and quotes what it printed.
    stderr.write(`settings.mjs: ${error.message}\n`);
    return 1;
  }
  stdout.write(text);
  return 0;
}

// Run as a program rather than imported - the same guard as
// scripts/release/build-info.mjs.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(path.resolve(process.argv[1]))) {
  process.exitCode = main(process.argv.slice(2));
}
