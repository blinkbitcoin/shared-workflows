#!/usr/bin/env node
// The ports of an app's local services, derived from one base.
//
//   ports            the table: each service's port, its offset and override
//   ports --sh       `export` lines for every derived value, to eval:
//                    eval "$(pnpm exec ports --sh)"
//   ports --root DIR  read DIR's app-tooling.json instead of the current directory's
//
// A Makefile's run targets eval the second form, so they work in a shell with no
// mise activated and `APP_PORT_BASE=8090 make dev` moves every service. The table
// is the family's (Metro +1, mock API +2, web preview +3) unless the `ports`
// section of app-tooling.json names another: `base`, `services` and `apiPath`.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { ConfigError, portTable, readSection } from '../lib/config.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { envLines, PortError, tableLines } from '../lib/ports.mjs';

const USAGE = 'usage: ports [--sh] [--root DIR]';

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    env = process.env,
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
  } = {},
) {
  let shell = false;
  let root = cwd;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--sh') shell = true;
    else if (argv[i] === '--root' && argv[i + 1]) root = path.resolve(cwd, argv[++i]);
    else {
      error(USAGE);
      return 2;
    }
  }
  try {
    const table = portTable(readSection(root, 'ports', read));
    log((shell ? envLines(env, table) : tableLines(env, table)).join('\n'));
    return 0;
  } catch (e) {
    if (!(e instanceof ConfigError || e instanceof PortError)) throw e;
    error(`ports: ${e.message}`);
    return 2;
  }
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
