import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { main as program } from './bin/check-ports.mjs';
import * as entry from './lib/check-ports-main.mjs';

test("it exports the program's entry and none of its helpers", () => {
  assert.deepEqual(Object.keys(entry), ['main']);
  assert.equal(entry.main, program);
});

test('the package exports it as check-ports, and still runs the program itself as the check-ports bin', () => {
  const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'));
  assert.equal(pkg.exports['./check-ports'], './lib/check-ports-main.mjs');
  assert.equal(pkg.bin['check-ports'], './bin/check-ports.mjs');
});
