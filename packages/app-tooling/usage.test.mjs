import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { answerHelp, HELP_FLAGS, usage, wantsHelp } from './lib/usage.mjs';

const BIN = fileURLToPath(new URL('./bin/', import.meta.url));
const programs = readdirSync(BIN).filter((file) => file.endsWith('.mjs') && !file.includes('.test.'));

test('--help and -h ask for the usage, anywhere on the command line; nothing else does', () => {
  assert.deepEqual(HELP_FLAGS, ['--help', '-h']);
  assert.equal(wantsHelp(['--help']), true);
  assert.equal(wantsHelp(['--root', 'app', '-h']), true);
  assert.equal(wantsHelp([]), false);
  assert.equal(wantsHelp(['--root', 'app', '--helpful', 'h']), false);
});

test('usage is the leading comment after the #! line, its markers off and its trailing blank lines dropped', () => {
  const source = '#!/usr/bin/env node\n// What it does.\n//\n//   tool [--root DIR]\n//\nimport x from "y";\n// not the header\n';
  assert.equal(usage(source), 'What it does.\n\n  tool [--root DIR]');
});

test('usage reads a source without a #! line, and one with no header at all as empty', () => {
  assert.equal(usage('// A module.\n//no space after the marker\nexport {};\n'), 'A module.\nno space after the marker');
  assert.equal(usage('export {};\n'), '');
});

test('answerHelp prints the usage of the module it is given and says so, or prints nothing', () => {
  const printed = [];
  const url = new URL('./bin/help.mjs', import.meta.url).href;
  assert.equal(answerHelp(['--root', 'x'], url, (text) => printed.push(text)), false);
  assert.deepEqual(printed, []);
  assert.equal(answerHelp(['-h'], url, (text) => printed.push(text)), true);
  assert.equal(printed.length, 1);
  assert.match(printed[0], /^`make help`: every `##`-documented target/);
  assert.match(printed[0], /^ {2}help \[--root DIR\]$/m);
  assert.doesNotMatch(printed[0], /^\/\//m);
});

// The header is the one copy of each program's usage, so it is held to naming
// the program in a synopsis line: an indented line that starts with its name.
test('every program under bin/ has a header with a synopsis line naming it', () => {
  assert.ok(programs.length > 30, `only ${programs.length} programs found`);
  for (const file of programs) {
    const name = file.replace(/\.mjs$/, '');
    const text = usage(readFileSync(`${BIN}${file}`, 'utf8'));
    const synopsis = new RegExp(`^ +(?:[A-Z_]+=\\S+ )?${name}(?: |$)`, 'm');
    assert.match(text, synopsis, `${file}: no synopsis line naming ${name} in its header`);
  }
});
