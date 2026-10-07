#!/usr/bin/env node
// GitHub Actions reads only the top level of .github/workflows, so a filename
// prefix is the only grouping the directory has. Every workflow file belongs to
// a named group, and where a group has a display name, the workflow's `name:`
// says the same thing its filename does.
//
//   check-workflow-names --group PREFIX[=DISPLAY] ... [--root DIR] [--min-files N]
//
// `--group ci=CI --group cd=CD` is the template's rule: `ci.yml` shows as `CI`,
// `ci-*.yml` as `CI / ...`, `cd-*.yml` as `CD / ...`. `--group check` alone
// only requires the prefix (`check.yml` or `check-*.yml`), which is
// shared-workflows' rule for its own stages. Files are spelled `.yml`: GitHub
// reads `.yaml` too, but one spelling keeps a glob and a grep honest.
//
// --min-files N fails a directory holding fewer than N workflow files (default
// 1), so a root that points somewhere else fails instead of passing.
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

/** The top-level `name:` of a workflow file, unquoted, or null when it has none. */
export function displayName(text) {
  const line = text.split('\n').find((l) => l.startsWith('name:'));
  return line
    ? line
        .slice('name:'.length)
        .trim()
        .replace(/^['"]|['"]$/g, '')
    : null;
}

/** Each `--group PREFIX[=DISPLAY]`, `--root DIR` and `--min-files N`, as `{ root, groups, minFiles }`. */
export function parseArgs(argv, cwd) {
  let root = cwd;
  let minFiles = 1;
  const groups = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    const group = /^([a-z0-9]+)(?:=(\S.*))?$/.exec(value ?? '');
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else if (arg === '--group' && group) groups.push({ prefix: group[1], display: group[2] ?? null });
    else if (arg === '--min-files' && /^[1-9][0-9]*$/.test(value ?? '')) minFiles = Number(value);
    else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --group PREFIX[=DISPLAY], --root DIR and --min-files N`);
  }
  if (groups.length === 0) throw new Error('name at least one --group');
  return { root, groups, minFiles };
}

/** Why each workflow does not fit a group, one sentence per file. */
export function problems(workflows, groups) {
  const found = [];
  for (const { file, text } of workflows) {
    const group = groups.find(({ prefix }) => file === `${prefix}.yml` || new RegExp(`^${prefix}-[a-z0-9-]+\\.yml$`).test(file));
    if (!group) {
      found.push(`${file} is in no group: name it ${groups.map((g) => `${g.prefix}-*.yml`).join(' or ')}, spelled .yml`);
      continue;
    }
    if (!group.display) continue;
    const name = displayName(text);
    const want = file === `${group.prefix}.yml` ? group.display : `${group.display} / ...`;
    // Something other than blanks has to follow `DISPLAY / `: a quoted name can
    // keep trailing spaces, and `"CI /  "` names nothing.
    const fits =
      file === `${group.prefix}.yml`
        ? name === group.display
        : name?.startsWith(`${group.display} / `) && name.slice(group.display.length + 3).trim() !== '';
    if (!fits) found.push(`${file} displays as ${name === null ? 'nothing (no top-level name:)' : `"${name}"`}, not "${want}"`);
  }
  return found;
}

/** Every file in a workflow directory, with its text. */
function readWorkflows(dir) {
  return readdirSync(dir)
    .sort()
    .map((file) => ({ file, text: readFileSync(path.join(dir, file), 'utf8') }));
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), read = readWorkflows } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`workflow names: ${e.message}`);
    return 1;
  }
  const dir = path.join(options.root, '.github', 'workflows');
  let workflows;
  try {
    workflows = read(dir);
  } catch (e) {
    error(`workflow names: could not read ${dir}: ${e.message}`);
    return 1;
  }
  // A directory that reads empty would pass every rule below.
  if (workflows.length === 0) {
    error(`workflow names: no workflow file in ${dir}`);
    return 1;
  }
  if (workflows.length < options.minFiles) {
    error(`workflow names: ${workflows.length} workflow file(s) in ${dir}, fewer than --min-files ${options.minFiles}`);
    return 1;
  }
  const found = problems(workflows, options.groups);
  if (found.length > 0) {
    for (const problem of found) error(problem);
    error(`workflow names: ${found.length} workflow(s) outside their group's naming`);
    return 1;
  }
  log(`workflow names ok (${workflows.length} workflows)`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
