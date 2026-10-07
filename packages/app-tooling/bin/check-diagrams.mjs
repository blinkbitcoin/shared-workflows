#!/usr/bin/env node
// Parse-check every fenced ```mermaid block in the docs.
//
// This repo keeps its diagrams as GitHub-native fences rather than rendering
// `.mmd` sources to committed SVGs: GitHub draws the fence, so an SVG artifact,
// an assembler and a regeneration hook would be machinery with no reader. What
// that costs is validation — a malformed diagram merges happily and renders as
// a grey error box — so the blocks are extracted here and fed to the same
// mermaid parser GitHub uses, pinned to one version.
//
//   check-diagrams [--all] [files...]
//
// With no arguments only docs that changed against origin/main are checked, so
// the usual `make check-docs` costs nothing; `--all` checks the whole doc set
// and is what CI runs.
//
// This is the one gate that needs the network on a cold npx cache. Whether the
// toolchain works is settled once, up front, by rendering a diagram this file
// owns (PROBE_DIAGRAM) — never by reading the parser's complaints about the
// docs' own diagrams. When that probe fails locally the check skips rather than
// blocking an offline developer; under CI it fails, because a runner that
// cannot render is a broken gate and a warning nobody reads is how a gate dies.
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { DOC_EXCLUDES, DOC_GLOBS, docFiles, fencedBlocks } from './check-docs-tables.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

// Pinned, not `@latest`: the parser is the thing under test, so a mermaid
// release must be a reviewed commit here rather than a check that changes its
// mind overnight. Same pin as the sibling repos.
export const MERMAID_CLI = '@mermaid-js/mermaid-cli@11.16.0';

/**
 * Every fenced mermaid block in `markdown`, as `{ line, code }` with `line` the
 * 1-based line of the opening fence. Handles indented fences (a block inside a
 * list item) and nested fences: a ```` ```mermaid ```` inside a longer fence is
 * that outer block's content, not a diagram.
 */
export function extractMermaidBlocks(markdown) {
  return (
    fencedBlocks(markdown.split('\n'))
      // An unclosed fence is a markdown bug, not a diagram; leave it to the reader.
      .filter((block) => block.info === 'mermaid' && block.closed)
      .map((block) => ({ line: block.start + 1, code: block.body.join('\n') }))
  );
}

/** The subset of `files` that contains at least one mermaid block. */
export function filesWithMermaid(files, read) {
  return files.filter((file) => extractMermaidBlocks(read(file)).length > 0);
}

// A diagram this file owns, used to decide whether the toolchain works at all.
// It must never come from the docs: the whole point is that the thing being
// checked cannot influence the decision to check it.
// mermaid-cli renders through puppeteer, which needs a Chromium to drive. `npx`
// fetches the CLI on demand but not reliably a browser with it, so prefer one
// the machine already has: GitHub runner images ship Chrome and export
// CHROME_BIN, and a Mac keeps it under /Applications. Finding none, the config
// names no executable and puppeteer falls back to whatever it downloaded.
export const BROWSER_PATHS = [
  process.env.PUPPETEER_EXECUTABLE_PATH,
  process.env.CHROME_BIN,
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
];

/** The first entry of `paths` that exists, or undefined. */
export function findBrowser(paths = BROWSER_PATHS, exists = existsSync) {
  return paths.find((candidate) => candidate && exists(candidate));
}

/**
 * Writes the puppeteer config `mmdc -p` takes, and returns its path.
 *
 * `--no-sandbox` because a CI container has no user namespace to sandbox with,
 * and `--disable-dev-shm-usage` because its /dev/shm is smaller than Chromium
 * assumes. Both are inert on a developer machine, so there is one code path.
 */
export function writePuppeteerConfig(dir, executablePath) {
  const config = { args: ['--no-sandbox', '--disable-dev-shm-usage'] };
  if (executablePath) config.executablePath = executablePath;
  const file = path.join(dir, 'puppeteer.json');
  writeFileSync(file, `${JSON.stringify(config)}\n`);
  return file;
}

export const PROBE_DIAGRAM = 'graph TD;\n  A-->B;';

/**
 * Whether `run` can render at all, decided by rendering PROBE_DIAGRAM — a
 * known-good diagram — rather than by reading the parser's complaints.
 *
 * The earlier version sniffed `mmdc`'s stderr for words like "network" or
 * "command not found" to tell an offline npx from a broken diagram. That was
 * unsound: `mmdc` echoes the diagram source back in its parse errors
 * ("...for text: <the block>"), so a malformed diagram containing any of those
 * words classified itself as an environment problem and turned the gate off.
 * The one failure mode a gate must not have. Availability is now settled once,
 * before a single doc block is read, and every later non-zero exit is the
 * diagram's fault by construction.
 */
export function probeToolchain(run) {
  const { status, stderr } = run(PROBE_DIAGRAM);
  return status === 0 ? { available: true } : { available: false, stderr };
}

/** `message` without npx's own config chatter, which is never the diagnosis. */
export function cleanOutput(message, lines = 4) {
  return (message ?? '')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !/^npm (warn|notice)\b/.test(l))
    .slice(0, lines)
    .join(' ');
}

/** One report line per broken block, pointing at the fence that opened it. */
export function formatParseError(file, block, message) {
  const first = cleanOutput(message);
  return `${file}:${block.line}: mermaid block does not parse — ${first || 'no parser output'}`;
}

/**
 * Check one block with `run(code)`, which must return `{ status, stderr }`.
 * Called only after `probeToolchain` said the toolchain works, so a non-zero
 * exit here is a parse failure and nothing else.
 */
export function checkBlock(file, block, run) {
  const { status, stderr } = run(block.code);
  return status === 0 ? { ok: true } : { error: formatParseError(file, block, stderr) };
}

/** Docs changed against origin/main, or undefined when git cannot tell. */
export function changedDocs(exec = execFileSync) {
  try {
    const out = exec('git', ['diff', '--name-only', 'origin/main...HEAD'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return out
      .split('\n')
      .filter(Boolean)
      .filter((f) => f.endsWith('.md') && !DOC_EXCLUDES.some((p) => f.startsWith(p)));
  } catch {
    return undefined; // no origin/main, shallow clone: check everything
  }
}

// One `npx` process per diagram, plus one for the probe. The doc set has a
// single block today, so this is two spawns; past roughly three blocks it is
// worth writing them all into `dir` and handing `mmdc` the directory once
// (`-i dir`), or resolving the CLI once with a warm `npx --no-install`.
export function mmdcRunner(dir, spawn = spawnSync, browser = findBrowser()) {
  const puppeteerConfig = writePuppeteerConfig(dir, browser);
  let n = 0;
  return (code) => {
    const input = path.join(dir, `block-${n++}.mmd`);
    writeFileSync(input, `${code}\n`);
    const result = spawn(
      'npx',
      ['--yes', MERMAID_CLI, '--quiet', '-p', puppeteerConfig, '-i', input, '-o', `${input}.svg`],
      { encoding: 'utf8' },
    );
    // A spawn that never started (no npx on PATH) has no exit code of its own.
    if (result.error) return { status: 1, stderr: `could not run npx: ${result.error.message}` };
    return { status: result.status, stderr: `${result.stderr ?? ''}${result.stdout ?? ''}` };
  };
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    log = console.log,
    error = console.error,
    env = process.env,
    read = (file) => readFileSync(file, 'utf8'),
    listDocs = () => docFiles(DOC_GLOBS, DOC_EXCLUDES),
    changed = changedDocs,
    runner = mmdcRunner,
  } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  const all = argv.includes('--all');
  const explicit = argv.filter((a) => a !== '--all');
  // A flag this does not know, or a file it was named that is not there, used
  // to fall through to "diagrams ok": a typo passed the gate it was meant to run.
  const flag = explicit.find((a) => a.startsWith('-'));
  if (flag !== undefined) {
    error(`::error::check-diagrams: unexpected ${flag}: pass --all and file paths`);
    return 1;
  }
  const missing = explicit.filter((file) => {
    try {
      read(file);
      return false;
    } catch {
      return true;
    }
  });
  if (missing.length > 0) {
    error(`::error::check-diagrams: no such file: ${missing.join(', ')}`);
    return 1;
  }

  let candidates;
  if (explicit.length > 0) {
    candidates = explicit;
  } else if (all) {
    candidates = listDocs();
  } else {
    const docs = changed();
    candidates = docs === undefined ? listDocs() : docs;
  }
  const files = filesWithMermaid(
    candidates.filter((file) => {
      try {
        read(file);
        return true;
      } catch {
        return false; // deleted in the working tree
      }
    }),
    read,
  );

  if (files.length === 0) {
    log('diagrams ok (no changed doc has a mermaid block)');
    return 0;
  }

  const dir = mkdtempSync(path.join(tmpdir(), 'check-diagrams-'));
  const run = runner(dir);
  const errors = [];
  let blocks = 0;
  let probe;
  try {
    // Availability first, on our own diagram. Nothing from the docs has been
    // handed to the CLI at this point, so nothing in the docs can turn the
    // gate off.
    probe = probeToolchain(run);
    if (probe.available) {
      for (const file of files) {
        for (const block of extractMermaidBlocks(read(file))) {
          blocks++;
          const { error: failure } = checkBlock(file, block, run);
          if (failure) errors.push(failure); // collect them all; never stop early
        }
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  if (!probe.available) {
    const why = cleanOutput(probe.stderr, 2) || 'no output';
    const message = `${MERMAID_CLI} could not render a known-good diagram (${why})`;
    // A runner is expected to have both the network and a browser, so a probe
    // failure there is the gate breaking, not an environment to work around.
    if (env.CI) {
      error(`::error::diagrams: ${message}`);
      return 1;
    }
    error(
      `warning: mermaid check skipped: ${message} — this gate needs the network on a cold npx cache`,
    );
    return 0;
  }

  if (errors.length > 0) {
    for (const line of errors) error(line);
    error(`diagrams: ${errors.length} mermaid block(s) do not parse`);
    return 1;
  }
  log(`diagrams ok (${blocks} mermaid block(s) in ${files.length} file(s))`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
