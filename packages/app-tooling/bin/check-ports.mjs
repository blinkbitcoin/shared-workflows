#!/usr/bin/env node
// No tracked file hardcodes a port that `APP_PORT_BASE` is supposed to move.
//
//   check-ports [--root DIR]
//
// The ports are derived (see `ports`), so a literal 8081 in a script or a doc is
// a place the base cannot reach: it works until someone sets `APP_PORT_BASE`,
// and then half the tooling talks to the wrong port. This lists every tracked
// text file with a line that uses one of the app's ports as a port, and fails.
//
// The numbers to look for are the base, every service's default port, and the
// `retired` ports named in the `ports` section of app-tooling.json (so a copy-paste
// from an older branch is caught too). A file may carry one for a reason that is not
// "we forgot": the `allow` object names each such path or directory prefix and why.
// A file with a reason is a reviewed exception; one with none is a finding.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { ConfigError, portTable, readSection, stringMap } from '../lib/config.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { isAllowed, isBinary, portPattern } from '../lib/port-literals.mjs';
import { BASE_DEFAULT, resolvePorts } from '../lib/ports.mjs';

const USAGE = 'usage: check-ports [--root DIR]';

/** The tracked files under `root`, relative, NUL-separated by git so any name survives. */
export function trackedFiles(root) {
  return execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
}

/** `file:line: text` for every line of `files` that uses one of the ports as a port. */
export function offenders(root, files, pattern, { isText = (absolute) => !isBinary(absolute), read = (absolute) => readFileSync(absolute, 'utf8') } = {}) {
  const found = [];
  for (const file of files) {
    const absolute = path.join(root, file);
    let content;
    try {
      if (!isText(absolute)) continue;
      content = read(absolute);
    } catch {
      continue; // gone, or unreadable: nothing to match
    }
    content.split('\n').forEach((line, i) => {
      if (pattern.test(line)) found.push(`${file}:${i + 1}: ${line.trim()}`);
    });
  }
  return found;
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { cwd = process.cwd(), log = console.log, error = console.error, list = trackedFiles, scan = offenders, env = {} } = {},
) {
  let root = cwd;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root' && argv[i + 1]) root = path.resolve(cwd, argv[++i]);
    else {
      error(USAGE);
      return 2;
    }
  }
  try {
    const read = (file) => {
      try {
        return readFileSync(file, 'utf8');
      } catch {
        return null;
      }
    };
    const section = readSection(root, 'ports', read);
    const table = portTable(section);
    const allow = Object.keys(section?.allow === undefined ? {} : stringMap(section.allow, 'ports.allow'));
    const retired = section?.retired ?? [];
    if (!Array.isArray(retired) || !retired.every((port) => Number.isInteger(port) && port > 0 && port < 65536)) {
      throw new ConfigError('app-tooling.json: "ports.retired" must be a list of port numbers');
    }
    const ports = resolvePorts(env, table);
    const literals = [...new Set([table.base ?? BASE_DEFAULT, ...Object.entries(ports).filter(([key]) => key !== 'base').map(([, port]) => port), ...retired])];
    const found = scan(root, list(root).filter((file) => !isAllowed(file, allow)), portPattern(literals));
    if (found.length > 0) {
      for (const line of found) error(line);
      error(`check-ports: ${found.length} hardcoded port(s). Derive them from APP_PORT_BASE with \`ports\`, or name the file in "ports.allow" of app-tooling.json with a reason`);
      return 1;
    }
    log(`ports ok (${literals.join(', ')}; ${allow.length} allowed)`);
    return 0;
  } catch (e) {
    if (!(e instanceof ConfigError)) throw e;
    error(`check-ports: ${e.message}`);
    return 2;
  }
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
