#!/usr/bin/env node
// GitHub's CodeQL analysis, on this machine: the same language, query suite,
// packs and path exclusions as check-code-scanning.yml reads from the repository's
// configuration file - and so the same findings, before a push, with each
// inline `// codeql[<rule-id>]` marker shown as suppressing its finding or not.
//
//   check-code-scanning [--root DIR] [--config FILE] [--language LANGUAGE]
//
// --config defaults to `.github/codeql/codeql-config.yml`, check-code-scanning.yml's
// own default. --language defaults to its default too, `javascript-typescript`,
// the one language mapped here: the suite path and the query pack are named
// after the language, so another one needs this mapping extended rather than
// guessed. The workflow reads the queries out of the same file, and so does
// this; an entry it does not recognise stops the run rather than being
// dropped, because a local run that analyses less than CI is how a local
// "clean" stops meaning a CI "clean".
//
// The CLI is `codeql` on PATH, else the `gh codeql` extension. Output goes to
// `.codeql/` in the root (the database, results.sarif and the two tool logs),
// which the repository ignores. The first run downloads and compiles the query
// pack, which takes minutes. Exits 1 while any finding is unsuppressed, so it
// works as a pre-push gate. It is a local check: CI runs CodeQL on GitHub.
import { spawnSync } from 'node:child_process';
import { accessSync, constants, mkdirSync, openSync, closeSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';

const LANGUAGES = {
  'javascript-typescript': { pack: 'codeql/javascript-queries', suitePrefix: 'javascript' },
};
const OUT = '.codeql';

const INSTALL = `codeql: no CodeQL CLI found. Install one of:

  gh extension install github/gh-codeql   # then: gh codeql --help
  brew install codeql                     # or unpack a release from
                                          # https://github.com/github/codeql-cli-binaries/releases
                                          # and put \`codeql\` on PATH

This gate is local-only; CI runs CodeQL on GitHub either way.`;

/**
 * The items of the top-level YAML list `key` in `text`, with trailing comments
 * and blanks stripped. Scoped to that key's block on purpose: an unscoped
 * search for `- codeql/...` would also match such a line in a comment, in
 * another key's list, or in prose.
 */
export function yamlList(text, key) {
  const lines = text.split('\n');
  const start = lines.findIndex((line) => line.startsWith(`${key}:`));
  if (start === -1) return [];
  const items = [];
  for (const line of lines.slice(start + 1)) {
    if (/^[^ #-]/.test(line)) break;
    const item = /^\s*-\s*(.*)$/.exec(line);
    if (!item) continue;
    const value = item[1].replace(/\s*#.*$/, '').trimEnd();
    if (value !== '') items.push(value);
  }
  return items;
}

/**
 * What the configuration asks CodeQL for: `{ queries, filters, warnings }`,
 * or a thrown Error naming the entry it cannot map.
 */
export function plan(text, config, language) {
  const { pack, suitePrefix } = LANGUAGES[language];
  const entries = yamlList(text, 'queries');
  if (entries.length !== 1) {
    throw new Error(
      `${config} names ${entries.length} entries under 'queries:'; this check maps exactly one suite. Extend it rather than letting the local run analyse less than CI does.`,
    );
  }
  if (!entries[0].startsWith('uses:')) {
    throw new Error(`unsupported 'queries:' entry '${entries[0]}' in ${config} - expected 'uses: <suite>'`);
  }
  // `uses: security-and-quality` is the action's shorthand for the pack's
  // javascript-security-and-quality.qls; the CLI wants that path spelled out.
  // A path or a local .ql file would be handed to the CLI verbatim by the
  // action and mangled here.
  const suite = entries[0].slice('uses:'.length).trim();
  if (suite === '' || /\/|\.qls?$/.test(suite)) {
    throw new Error(`unsupported 'uses:' form '${suite}' in ${config} - this check maps a bare suite name (e.g. security-and-quality)`);
  }
  const queries = [`${pack}:codeql-suites/${suitePrefix}-${suite}.qls`];
  // Every pack in the `packs:` block - above all AlertSuppression.ql, without
  // which the inline markers are ignored and this run disagrees with CI about
  // what is still open.
  for (const entry of yamlList(text, 'packs')) {
    if (!entry.includes('/')) throw new Error(`unsupported 'packs:' entry '${entry}' in ${config} - expected <scope>/<name>[:<path>]`);
    queries.push(entry);
  }
  const warnings = queries.some((query) => query.endsWith('AlertSuppression.ql'))
    ? []
    : [`::warning::${config} loads no AlertSuppression.ql pack, so inline // codeql[rule-id] markers count for nothing - here or in CI`];
  // The same paths-ignore list, as index filters, one per entry exactly as
  // written: a directory excludes its whole subtree on its own, and the
  // extractor rejects a trailing `/**` ("Illegal use of '**' in exclude path").
  const filters = [...yamlList(text, 'paths-ignore'), OUT].map((entry) => `exclude:${entry}`);
  return { queries, filters, warnings };
}

const location = (result) => {
  const physical = result.locations?.[0]?.physicalLocation;
  const uri = physical?.artifactLocation?.uri ?? '<no location>';
  const line = physical?.region?.startLine;
  return line === undefined ? uri : `${uri}:${line}`;
};

/** Every result across a SARIF log's runs, in report order. */
export const findings = (sarif) =>
  (sarif.runs ?? []).flatMap((run) =>
    (run.results ?? []).map((result) => ({
      // A result with no ruleId is still a finding; dropping it because it
      // cannot be named is how a real one goes unnoticed.
      ruleId: result.ruleId ?? '<no rule>',
      location: location(result),
      message: (result.message?.text ?? '').replace(/\s+/g, ' ').trim(),
      // SARIF producers emit `suppressions: []` for an unsuppressed result.
      suppressed: (result.suppressions ?? []).length > 0,
    })),
  );

/** The report lines and the counts for a SARIF log. */
export const summarize = (sarif) => {
  const all = findings(sarif);
  const open = all.filter((f) => !f.suppressed).length;
  const suppressed = all.length - open;
  const lines = all.map((f) => `${f.suppressed ? 'suppressed' : 'open      '}  ${f.ruleId}  ${f.location}  ${f.message}`);
  lines.push(all.length === 0 ? 'codeql: no findings' : `codeql: ${open} open, ${suppressed} suppressed by an inline marker`);
  return { open, suppressed, lines };
};

/** The arguments, as `{ root, config, language }`. */
export function parseArgs(argv, cwd) {
  const options = { root: cwd, config: '.github/codeql/codeql-config.yml', language: 'javascript-typescript' };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--root' && value) options.root = path.resolve(cwd, value);
    else if (arg === '--config' && value) options.config = value;
    else if (arg === '--language' && value) {
      if (!LANGUAGES[value]) throw new Error(`--language ${value} is not mapped; this check knows ${Object.keys(LANGUAGES).join(', ')}`);
      options.language = value;
    } else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --root DIR, --config FILE and --language LANGUAGE`);
  }
  return options;
}

/** Whether `name` is an executable on the PATH in `env`. */
export function onPath(name, env) {
  return (env.PATH ?? '').split(path.delimiter).some((dir) => {
    try {
      accessSync(path.join(dir, name), constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

/** A command's status and output, run in `cwd`. */
export function capture(command, args, { cwd, env }) {
  const result = spawnSync(command, args, { cwd, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  return { status: result.status, stdout: result.stdout ?? '' };
}

/** A command run in `cwd` with its output, both streams, written to `logFile`; returns its status. */
export function logged(command, args, { cwd, env, logFile }) {
  const fd = openSync(logFile, 'w');
  try {
    return spawnSync(command, args, { cwd, env, stdio: ['ignore', fd, fd] }).status;
  } finally {
    closeSync(fd);
  }
}

/** The CodeQL CLI as a command and its leading arguments, or null when there is none. */
export function findCli(env, cwd) {
  if (onPath('codeql', env)) return ['codeql'];
  // Read whole, not piped into an early-exiting grep: gh then dies of SIGPIPE
  // and an installed extension reads as missing.
  if (onPath('gh', env) && capture('gh', ['extension', 'list'], { cwd, env }).stdout.includes('gh codeql')) return ['gh', 'codeql'];
  return null;
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), env = process.env } = {},
) {
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`code scanning: ${e.message}`);
    return 1;
  }
  const { root, config, language } = options;
  const cli = findCli(env, root);
  if (cli === null) {
    error(INSTALL);
    return 1;
  }
  let text;
  try {
    text = readFileSync(path.join(root, config), 'utf8');
  } catch {
    error(`::error::no CodeQL config at ${config}`);
    return 1;
  }
  let steps;
  try {
    steps = plan(text, config, language);
  } catch (e) {
    error(`::error::${e.message}`);
    return 1;
  }
  const [command, ...lead] = cli;
  const out = path.join(root, OUT);
  mkdirSync(out, { recursive: true });
  const version = capture(command, [...lead, 'version', '--format=terse'], { cwd: root, env }).stdout.trim();
  log(`== codeql ${version}, config ${config}`);
  for (const warning of steps.warnings) log(warning);

  const tail = (name) => {
    const lines = readFileSync(path.join(out, name), 'utf8').replace(/\n$/, '').split('\n');
    for (const line of lines.slice(-30)) error(line);
  };
  log(`== database (${language}, no build step; ${steps.filters.length} index filters from ${config})`);
  const created = logged(command, [...lead, 'database', 'create', `${OUT}/db`, `--language=${language}`, '--source-root', '.', '--overwrite'], {
    cwd: root,
    env: { ...env, LGTM_INDEX_FILTERS: steps.filters.join('\n') },
    logFile: path.join(out, 'create.log'),
  });
  if (created !== 0) {
    tail('create.log');
    error(`::error::database create failed (full log: ${OUT}/create.log)`);
    return 1;
  }
  log(`== analyze: ${steps.queries.join(' ')} (the pack is downloaded once)`);
  const analysed = logged(
    command,
    [...lead, 'database', 'analyze', `${OUT}/db`, ...steps.queries, '--download', '--format=sarif-latest', `--output=${OUT}/results.sarif`],
    { cwd: root, env, logFile: path.join(out, 'analyze.log') },
  );
  if (analysed !== 0) {
    tail('analyze.log');
    error(`::error::analyze failed (full log: ${OUT}/analyze.log)`);
    return 1;
  }
  log(`== findings (${OUT}/results.sarif)`);
  let sarif;
  try {
    sarif = JSON.parse(readFileSync(path.join(out, 'results.sarif'), 'utf8'));
  } catch (e) {
    error(`::error::could not read ${OUT}/results.sarif: ${e.message}`);
    return 1;
  }
  const { open, lines } = summarize(sarif);
  for (const line of lines) log(line);
  return open > 0 ? 1 : 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
