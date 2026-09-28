#!/usr/bin/env node
// No shell code changes a locale variable as a command prefix
// (`LC_ALL=C grep ...`); it hands the locale over with `env` instead
// (`env LC_ALL=C grep ...`).
//
//   check-shell-locale [--root DIR]
//
// Why a rule and not a style preference: with the prefix, bash sets the
// variable for the one command and restores it afterwards, and each of those is
// a setlocale() call inside bash. On macOS a bash linked against gettext
// (Homebrew's, first on PATH wherever Homebrew is installed) routes that
// through libintl_setlocale, which asks CoreFoundation for the user's preferred
// languages. Inside `$(...)` or a pipeline that runs in a forked child, where
// CoreFoundation is not fork-safe, and the child dies with SIGSEGV now and then:
// status 139, reported by the caller as if the command had failed. That is how
// `grep failed with status 139` came to fail the template's release
// verification intermittently on an unmodified checkout. `env` sets the
// variable in the command's own process only, so bash never changes locale.
//
// The crash is timing-dependent (about one fresh bash in twenty), so a test
// that runs the command and waits for it is not a test. This reads the source.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';

// A locale variable assigned on a line where another word follows it: the
// shape of a command prefix. A bare `LC_ALL=C` on its own line (or before a
// `;`) is not matched, and neither is anything inside a comment. The value is
// a bare word or one quoted word, so prose that merely mentions `LC_ALL=C` at
// the end of a quoted string ("... under LC_ALL=C" "next") is not a prefix.
const LOCALE_ASSIGNMENT_RE =
  /(?<![\w$-])(?:LC_[A-Z]+|LANG|LANGUAGE)=(?:"[^"\s]*"|'[^'\s]*'|[^\s;&|)"'`]*)[ \t]+(?=[^\s#;&|)])/g;

// What may legitimately stand in front of such an assignment: `env` hands the
// variable to a new process (the fix), and the declaration builtins set it in
// the current shell rather than for one command. Any further assignments
// between those words and the match are part of the same list.
const ALLOWED_HEAD_RE = /\b(?:env|export|local|declare|readonly|typeset)(?:[ \t]+-\S+)*(?:[ \t]+\w+=\S*)*[ \t]+$/;

/** Every locale-prefix assignment in `text`, as `<line number>: <line>`. */
export function localePrefixes(text) {
  const found = [];
  text.split('\n').forEach((line, i) => {
    if (line.trimStart().startsWith('#')) return;
    for (const match of line.matchAll(LOCALE_ASSIGNMENT_RE)) {
      if (ALLOWED_HEAD_RE.test(line.slice(0, match.index))) continue;
      found.push(`${i + 1}: ${line.trim()}`);
      break;
    }
  });
  return found;
}

/**
 * Whether a shell runs `file`: a script by extension or shebang, a Makefile's
 * recipes, a workflow's `run:` blocks (bash on the macOS runners too), or a
 * bats file.
 */
export function isShell(file, text) {
  if (/\.(?:sh|bash|bats)$/.test(file)) return true;
  if (path.basename(file) === 'Makefile') return true;
  if (/^\.github\/workflows\/.*\.ya?ml$/.test(file)) return true;
  return /^#!.*\b(?:bash|zsh|ksh|dash|sh)\b/.test(text.slice(0, text.indexOf('\n') + 1));
}

/** The files git tracks under `root`. */
function trackedFiles(root) {
  return execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
}

/** A file's text, or null for one that cannot be read (gone, a submodule entry). */
function readText(file) {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

/** `{ scanned, offenders }` over every tracked shell file under `root`. */
export function scan(root, { list = trackedFiles, read = readText } = {}) {
  const offenders = [];
  let scanned = 0;
  for (const file of list(root)) {
    const text = read(path.join(root, file));
    if (text === null || !isShell(file, text)) continue;
    scanned += 1;
    for (const hit of localePrefixes(text)) offenders.push(`${file}:${hit}`);
  }
  return { scanned, offenders };
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), list, read } = {},
) {
  const at = argv.indexOf('--root');
  const root = at === -1 ? cwd : path.resolve(cwd, argv[at + 1] ?? '');
  let result;
  try {
    result = scan(root, { list, read });
  } catch (e) {
    error(`shell locale: could not list the files of ${root}: ${e.message}`);
    return 1;
  }
  // A guard that silently scanned nothing would pass forever.
  if (result.scanned === 0) {
    error(`shell locale: no shell file found under ${root}; the file filter or the root is wrong`);
    return 1;
  }
  if (result.offenders.length > 0) {
    for (const offender of result.offenders) error(offender);
    error(
      `shell locale: ${result.offenders.length} locale variable(s) set as a command prefix, which crashes a forked bash on macOS now and then (status 139). Write \`env LC_ALL=C cmd\` instead`,
    );
    return 1;
  }
  log(`shell locale ok (${result.scanned} shell files)`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
