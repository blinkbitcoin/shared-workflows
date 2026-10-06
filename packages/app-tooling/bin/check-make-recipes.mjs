#!/usr/bin/env node
// A make target is a menu entry, not a program: its recipe is one line calling
// one tested script or program, or nothing at all (an aggregate that only lists
// prerequisites). Logic in a recipe is logic no test reaches and no CI job runs
// without make, so it drifts from what CI does and cannot be run anywhere else.
//
//   check-make-recipes [--root DIR] [--allow TARGET=REASON ...]
//
// One call is:
//   bash PATH.sh [ARGS]      a shell script
//   node PATH.mjs [ARGS]     a Node program
//   pnpm exec NAME [ARGS]    a package's program
//   pnpm [run] NAME [ARGS]   a package.json script
// with an optional leading `@` or `-`. Arguments may pass make variables
// through (`$(ARGS)`); `$(shell ...)`, `&&`, `||`, `;`, a pipe, a redirect, a
// backtick and a second recipe line (or a `\` continuation) are logic. The
// Makefile's `include`s are followed, so a shared fragment is held to the same
// rule. An exception is an --allow with its reason, and an allowance that no
// longer applies is itself a failure.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

const CALL = /^[@-]*(?:bash \S+\.sh|node \S+\.m?js|pnpm exec [\w@/.:-]+|pnpm (?:run )?[\w:.-]+)(?: .*)?$/;
const LOGIC = /&&|\|\||;|\||>|<|`|\$\(shell\b/;

/**
 * Every rule in `text` with its recipe lines, as `{ target, line, recipe }`
 * (`line` is where the rule starts; `recipe` is `[{ line, text }]`), and the
 * paths of its `include` lines that name a plain file.
 */
export function parseMakefile(text) {
  const rules = [];
  const includes = [];
  let current = null;
  for (const [index, raw] of text.split('\n').entries()) {
    const line = index + 1;
    if (raw.startsWith('\t')) {
      if (current) current.recipe.push({ line, text: raw.slice(1) });
      continue;
    }
    const include = /^-?include\s+(.+)$/.exec(raw);
    if (include) {
      includes.push(...include[1].trim().split(/\s+/).filter((file) => !file.includes('$(')));
      current = null;
      continue;
    }
    const rule = /^([a-zA-Z0-9_.-]+(?:\s+[a-zA-Z0-9_.-]+)*)\s*:(?!=)([^#]*)/.exec(raw);
    if (rule && !rule[1].startsWith('.')) {
      current = { target: rule[1].split(/\s+/)[0], line, recipe: [] };
      // `target: prerequisites ; command` is a recipe on the rule's own line.
      const inline = rule[2].indexOf(';');
      if (inline !== -1) current.recipe.push({ line, text: rule[2].slice(inline + 1) });
      rules.push(current);
      continue;
    }
    if (raw.trim() !== '' && !raw.startsWith('#')) current = null;
  }
  return { rules, includes };
}

/** Why a rule's recipe is not a single call, or null when it is. */
export function recipeProblem({ recipe }) {
  const lines = recipe.filter(({ text }) => text.trim() !== '' && !text.trim().startsWith('#'));
  if (lines.length === 0) return null;
  if (lines.length > 1) return `has ${lines.length} recipe lines`;
  const text = lines[0].text.trim();
  if (text.endsWith('\\')) return 'continues its recipe over several lines';
  if (LOGIC.test(text)) return `holds shell logic: ${text}`;
  if (!CALL.test(text)) return `does not call a script or program: ${text}`;
  return null;
}

/** `--root DIR` and each `--allow TARGET=REASON`, as `{ root, allowed }`. */
export function parseArgs(argv, cwd) {
  let root = cwd;
  const allowed = new Map();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else if (arg === '--allow' && /^[a-zA-Z0-9_.-]+=\s*\S/.test(value ?? '')) {
      const at = value.indexOf('=');
      allowed.set(value.slice(0, at), value.slice(at + 1).trim());
    } else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --root DIR and --allow TARGET=REASON`);
  }
  return { root, allowed };
}

const readOrNull = (file) => {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
};

/**
 * Every rule of the Makefile at `file` and of what it includes, each with the
 * file it is in. An include resolves against `root`, the directory make runs
 * in, as make itself resolves it. A missing include is reported, not skipped: a
 * fragment that is not there is a fragment nobody checked.
 */
export function collectRules(file, read, root = path.dirname(file), seen = new Set()) {
  if (seen.has(file)) return { rules: [], missing: [] };
  seen.add(file);
  const text = read(file);
  if (text === null) return { rules: [], missing: [file] };
  const { rules, includes } = parseMakefile(text);
  const found = { rules: rules.map((rule) => ({ ...rule, file })), missing: [] };
  for (const include of includes) {
    const nested = collectRules(path.resolve(root, include), read, root, seen);
    found.rules.push(...nested.rules);
    found.missing.push(...nested.missing);
  }
  return found;
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), read = readOrNull } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`make recipes: ${e.message}`);
    return 1;
  }
  const { root, allowed } = options;
  const makefile = path.join(root, 'Makefile');
  if (read(makefile) === null) {
    error(`make recipes: no Makefile in ${root}`);
    return 1;
  }
  const { rules, missing } = collectRules(makefile, read);
  const problems = missing.map((file) => `${path.relative(root, file)} is included and does not exist`);
  const flagged = new Set();
  for (const rule of rules) {
    const problem = recipeProblem(rule);
    if (problem === null) continue;
    flagged.add(rule.target);
    if (allowed.has(rule.target)) continue;
    problems.push(
      `${path.relative(root, rule.file)}:${rule.line} ${rule.target} ${problem}: move the logic into a tested script and call that`,
    );
  }
  for (const target of allowed.keys()) {
    if (!flagged.has(target)) problems.push(`--allow ${target} names no target with logic in its recipe; drop it`);
  }
  if (problems.length > 0) {
    for (const problem of problems) error(problem);
    error(`make recipes: ${problems.length} problem(s)`);
    return 1;
  }
  log(`make recipes ok (${rules.length} targets)`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
