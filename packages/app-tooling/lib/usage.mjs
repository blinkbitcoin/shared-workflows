// What a program prints for `--help` or `-h`: its own header comment.
//
// Every program under bin/ opens with a comment that says what it does and how
// it is called, the synopsis lines indented beneath it. That comment is the one
// copy of the usage: answerHelp reads it out of the program's file when asked,
// so the text `--help` prints and the text a reader of the source sees cannot
// drift apart, and no program carries a usage string beside it.
//
// A program calls answerHelp first thing in its `main`, before its own argument
// parsing, so a help flag anywhere on the command line prints the usage to
// standard output and exits 0, whatever else the program would have made of
// the arguments.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** The arguments that ask a program for its usage. */
export const HELP_FLAGS = ['--help', '-h'];

/** Whether any argument asks for the usage. */
export function wantsHelp(argv) {
  return argv.some((arg) => HELP_FLAGS.includes(arg));
}

/**
 * The leading `//` comment of a program's source, after its `#!` line, with the
 * comment markers taken off and trailing blank lines dropped.
 */
export function usage(source) {
  const lines = source.split('\n');
  if (lines[0].startsWith('#!')) lines.shift();
  const header = [];
  for (const line of lines) {
    if (!line.startsWith('//')) break;
    header.push(line.replace(/^\/\/ ?/, ''));
  }
  return header.join('\n').trimEnd();
}

/**
 * When `argv` asks for help, prints the usage of the program at `moduleUrl`
 * (its `import.meta.url`) through `print`, one call without a trailing newline,
 * and returns true; otherwise prints nothing and returns false. The caller
 * returns 0 on true.
 */
export function answerHelp(argv, moduleUrl, print) {
  if (!wantsHelp(argv)) return false;
  print(usage(readFileSync(fileURLToPath(moduleUrl), 'utf8')));
  return true;
}
