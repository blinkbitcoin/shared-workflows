#!/usr/bin/env node
// The static web export, ready for GitHub Pages.
//
//   build-web [expo export arguments...]
//
// `expo export --platform web`, then the router's `+not-found.html` copied to
// `404.html`: Pages serves `404.html` for a path with no file, which is how a
// deep link into a dynamic route boots the client router. Everything after the
// program name goes to `expo export` (`--dev` reads `.env.development`, which is
// how the web e2e suite builds against the mock API), except `--help` or `-h`,
// which prints this text instead of running anything.
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    cwd = process.cwd(),
    log = console.log,
    error = console.error,
    run = (command, args, options) => spawnSync(command, args, { stdio: 'inherit', ...options }),
    exists = existsSync,
    copy = copyFileSync,
  } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  const exported = run('pnpm', ['exec', 'expo', 'export', '--platform', 'web', ...argv], { cwd });
  if (exported.error) {
    error(`build-web: could not run pnpm exec expo: ${exported.error.message}`);
    return 1;
  }
  if (exported.status !== 0) return exported.status ?? 1;
  const notFound = path.join(cwd, 'dist', '+not-found.html');
  if (!exists(notFound)) {
    error('build-web: the export has no dist/+not-found.html, so there is no 404.html to publish. Does the app use expo-router with web.output "static"?');
    return 1;
  }
  copy(notFound, path.join(cwd, 'dist', '404.html'));
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
